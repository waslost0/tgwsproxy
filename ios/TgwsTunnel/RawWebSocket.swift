import Darwin
import Foundation
import Security

enum SocketError: Error, CustomStringConvertible {
  case resolve(String)
  case connect(Int32)
  case io(String)
  case badUpgrade(String)

  var description: String {
    switch self {
    case .resolve(let host): return "DNS resolve failed: \(host)"
    case .connect(let code): return "connect failed: errno \(code)"
    case .io(let message): return message
    case .badUpgrade(let line): return "WebSocket upgrade failed: \(line)"
    }
  }
}

/// Minimal blocking WebSocket client over a plain TCP socket.
///
/// The iOS route uses Cloudflare on port 80 (`?dst` is not needed for the
/// `kwsN` origin domains), so this deliberately stays on plain HTTP. TLS is
/// the next milestone once the relay itself is proven on the device.
final class RawWebSocket {
  private let fd: Int32
  private let closeLock = NSLock()
  private var closed = false
  private var fragmented = Data()

  init(host: String, port: UInt16, path: String, timeout: TimeInterval = 10) throws {
    var hints = addrinfo(
      ai_flags: 0,
      ai_family: AF_INET,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else {
      throw SocketError.resolve(host)
    }
    defer { freeaddrinfo(result) }

    var connected: Int32 = -1
    var lastError: Int32 = 0
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let info = current {
      let candidate = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
      if candidate >= 0 {
        Self.setSocketOptions(candidate, timeout: timeout)
        if connect(candidate, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
          connected = candidate
          break
        }
        lastError = errno
        Darwin.close(candidate)
      }
      current = info.pointee.ai_next
    }
    guard connected >= 0 else {
      throw SocketError.connect(lastError)
    }
    fd = connected
    try upgrade(host: host, path: path, timeout: timeout)
  }

  deinit { close() }

  func sendBinary(_ payload: Data) throws {
    try sendFrame(opcode: 0x2, payload: payload)
  }

  /// Returns one complete binary/text message, answering ping frames.
  func receiveMessage() throws -> Data? {
    var message = Data()
    var messageOpcode: UInt8 = 0

    while true {
      let header = try readExact(2)
      let first = header[0]
      let second = header[1]
      let fin = (first & 0x80) != 0
      let opcode = first & 0x0F
      var length = Int(second & 0x7F)

      if length == 126 {
        let raw = try readExact(2)
        length = Int(raw[0]) << 8 | Int(raw[1])
      } else if length == 127 {
        let raw = try readExact(8)
        length = 0
        for byte in raw { length = (length << 8) | Int(byte) }
      }

      var mask: [UInt8] = []
      if (second & 0x80) != 0 {
        mask = [UInt8](try readExact(4))
      }
      var payload = length > 0 ? [UInt8](try readExact(length)) : []
      if !mask.isEmpty {
        for index in payload.indices {
          payload[index] ^= mask[index % 4]
        }
      }

      switch opcode {
      case 0x8:
        return nil
      case 0x9:
        try sendFrame(opcode: 0xA, payload: Data(payload))
        continue
      case 0xA:
        continue
      case 0x0, 0x1, 0x2:
        if opcode != 0 { messageOpcode = opcode }
        message.append(contentsOf: payload)
        if fin {
          _ = messageOpcode
          return message
        }
      default:
        continue
      }
    }
  }

  func close() {
    closeLock.lock()
    defer { closeLock.unlock() }
    guard !closed else { return }
    closed = true
    shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
  }

  private func upgrade(host: String, path: String, timeout: TimeInterval) throws {
    let key = MtProto.randomBytes(16).base64EncodedString()
    let request = """
    GET \(path) HTTP/1.1\r
    Host: \(host)\r
    Upgrade: websocket\r
    Connection: Upgrade\r
    Sec-WebSocket-Key: \(key)\r
    Sec-WebSocket-Version: 13\r
    Sec-WebSocket-Protocol: binary\r
    \r

    """
    try sendAll(Data(request.utf8))
    var header = Data()
    while header.count < 16_384 {
      let byte = try readExact(1)
      header.append(byte)
      if header.count >= 4, header.suffix(4) == Data([13, 10, 13, 10]) {
        break
      }
    }
    guard let text = String(data: header, encoding: .utf8),
          let firstLine = text.components(separatedBy: "\r\n").first,
          firstLine.contains(" 101 ") else {
      RelayLog.write("ws upgrade failed: \(String(data: header, encoding: .utf8) ?? "<non-utf8>")")
      throw SocketError.badUpgrade(
        String(data: header, encoding: .utf8) ?? "<non-utf8>"
      )
    }
    RelayLog.write("ws upgrade ok: \(firstLine)")
    _ = timeout
  }

  private func sendFrame(opcode: UInt8, payload: Data) throws {
    var frame = Data()
    frame.append(0x80 | opcode)
    let length = payload.count
    // The mask bit is mandatory for client-to-server frames.
    if length < 126 {
      frame.append(0x80 | UInt8(length))
    } else if length <= 0xFFFF {
      frame.append(0x80 | 126)
      frame.append(UInt8((length >> 8) & 0xFF))
      frame.append(UInt8(length & 0xFF))
    } else {
      frame.append(0x80 | 127)
      let value = UInt64(length)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((value >> UInt64(shift)) & 0xFF))
      }
    }

    // Client-to-server frames must be masked.
    let mask = [UInt8](MtProto.randomBytes(4))
    frame.append(contentsOf: mask)
    for (index, byte) in payload.enumerated() {
      frame.append(byte ^ mask[index % 4])
    }
    try sendAll(frame)
  }

  private func readExact(_ count: Int) throws -> Data {
    if count == 0 { return Data() }
    var buffer = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let read = recv(fd, &buffer[offset], count - offset, 0)
      if read < 0 {
        throw SocketError.io("recv failed: errno \(errno)")
      }
      if read == 0 {
        throw SocketError.io("socket closed")
      }
      offset += read
    }
    return Data(buffer)
  }

  private func sendAll(_ data: Data) throws {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
      let sent = bytes.withUnsafeBytes {
        send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
      }
      if sent <= 0 {
        throw SocketError.io("send failed: errno \(errno)")
      }
      offset += sent
    }
  }

  private static func setSocketOptions(_ fd: Int32, timeout: TimeInterval) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    var value = timeval(
      tv_sec: Int(timeout),
      tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
  }
}
