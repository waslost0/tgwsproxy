import Darwin
import Foundation
import os.log

/// POSIX loopback listener inside the packet-tunnel extension.
///
/// Network Extension allows outbound sockets, and a blocking POSIX socket is
/// much simpler than bridging two `NWConnection` callback state machines. The
/// listener is still confined to 127.0.0.1.
final class RelayServer {
  private let port: UInt16
  private let secret: Data
  private let domain: String
  private let log: OSLog
  private let queue = DispatchQueue(label: "com.whitetigersoft.tgwsproxy.accept")
  private var listenFd: Int32 = -1
  private var running = false

  init(port: UInt16, secret: Data, domain: String, log: OSLog) {
    self.port = port
    self.secret = secret
    self.domain = domain
    self.log = log
  }

  func start() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw SocketError.io("listen socket failed: errno \(errno)")
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let code = errno
      Darwin.close(fd)
      throw SocketError.io("bind 127.0.0.1:\(port) failed: errno \(code)")
    }
    guard Darwin.listen(fd, 16) == 0 else {
      let code = errno
      Darwin.close(fd)
      throw SocketError.io("listen failed: errno \(code)")
    }

    listenFd = fd
    running = true
    os_log("relay listening on 127.0.0.1:%d", log: log, type: .info, port)
    RelayLog.write("relay listening on 127.0.0.1:\(port)")

    queue.async { [weak self] in
      self?.acceptLoop()
    }
  }

  func stop() {
    running = false
    if listenFd >= 0 {
      shutdown(listenFd, SHUT_RDWR)
      Darwin.close(listenFd)
      listenFd = -1
    }
  }

  private func acceptLoop() {
    while running {
      var address = sockaddr()
      var length = socklen_t(MemoryLayout<sockaddr>.size)
      let client = accept(listenFd, &address, &length)
      if client < 0 {
        if running {
          os_log("accept failed: errno %d", log: log, type: .error, errno)
        }
        continue
      }
      setSocketOptions(client)
      RelayLog.write("client accepted")
      let session = RelaySession(
        client: client,
        secret: secret,
        domain: domain,
        log: log
      )
      DispatchQueue.global(qos: .userInitiated).async {
        session.run()
      }
    }
  }

  private func setSocketOptions(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 130, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }
}

final class RelaySession {
  private let client: Int32
  private let secret: Data
  private let domain: String
  private let log: OSLog

  init(client: Int32, secret: Data, domain: String, log: OSLog) {
    self.client = client
    self.secret = secret
    self.domain = domain
    self.log = log
  }

  func run() {
    defer {
      shutdown(client, SHUT_RDWR)
      Darwin.close(client)
    }

    do {
      let handshakeBytes = try readExact(client, MtProto.handshakeLen)
      guard let handshake = MtProto.tryHandshake(handshakeBytes, secret: secret),
            let proto = MtProto.protoInt(handshake.protoTag) else {
        os_log("bad MTProto handshake", log: log, type: .error)
        RelayLog.write("bad MTProto handshake")
        return
      }
      RelayLog.write(
        "handshake dc=\(handshake.dc) media=\(handshake.media) proto=\(proto)"
      )

      var dc = handshake.dc
      if dc >= 10_000 { dc -= 10_000 }
      if dc == 203 { dc = 2 }
      let relayInit = MtProto.generateRelayInit(
        protoTag: handshake.protoTag,
        dcIdx: dc * (handshake.media ? -1 : 1)
      )
      let context = MtProto.buildCryptoContext(
        prekeyIv: handshake.prekeyIv,
        secret: secret,
        relayInit: relayInit
      )
      let splitter = MsgSplitter(proto: proto)

      let host = "kws\(dc).\(domain)"
      os_log("handshake dc=%d media=%d; connecting %{public}@",
             log: log, type: .info, dc, handshake.media ? 1 : 0, host)
      RelayLog.write("connecting \(host):80")
      let ws = try RawWebSocket(
        host: host,
        port: 80,
        path: "/apiws",
        timeout: 15
      )
      RelayLog.write("ws connected \(host)")
      try ws.sendBinary(relayInit)

      let group = DispatchGroup()
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        self.upstream(ws: ws, context: context, splitter: splitter)
        group.leave()
      }
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        self.downstream(ws: ws, context: context)
        group.leave()
      }
      group.wait()
      ws.close()
    } catch {
      os_log("relay session failed: %{public}@",
             log: log, type: .error, String(describing: error))
      RelayLog.write("session failed: \(error)")
    }
  }

  private func upstream(
    ws: RawWebSocket,
    context: CryptoContext,
    splitter: MsgSplitter
  ) {
    // A client EOF only closes its write direction. Do not tear down the
    // WebSocket here: the downstream pump still has a response to deliver.
    // The session's outer defer closes both sides when the group completes.
    var buffer = [UInt8](repeating: 0, count: 65_536)
    var sent = 0
    while true {
      let count = recv(client, &buffer, buffer.count, 0)
      if count <= 0 {
        RelayLog.write("upstream ended after \(sent) bytes")
        break
      }
      let chunk = Data(buffer[0..<count])
      let plain = context.clientDecrypt.process(chunk)
      let outbound = context.telegramEncrypt.process(plain)
      let parts = splitter.split(cipher: outbound, plain: plain)
      if sent == 0 {
        RelayLog.write(
          "first upstream \(count) plain \(hexPrefix(plain)) ws parts \(parts.map(\.count))"
        )
      }
      sent += count
      do {
        for part in parts {
          try ws.sendBinary(part)
        }
      } catch {
        os_log("upstream failed: %{public}@",
               log: log, type: .error, String(describing: error))
        RelayLog.write("upstream failed: \(error)")
        break
      }
    }
  }

  private func downstream(ws: RawWebSocket, context: CryptoContext) {
    defer {
      shutdown(client, SHUT_RDWR)
      ws.close()
    }
    var received = 0
    do {
      while let message = try ws.receiveMessage() {
        let plain = context.telegramDecrypt.process(message)
        if received == 0 {
          RelayLog.write(
            "first downstream \(message.count) plain \(hexPrefix(plain))"
          )
        }
        received += message.count
        let outbound = context.clientEncrypt.process(plain)
        try writeAll(client, outbound)
      }
      RelayLog.write("downstream closed after \(received) bytes")
    } catch {
      os_log("downstream failed: %{public}@",
             log: log, type: .error, String(describing: error))
      RelayLog.write("downstream failed: \(error)")
    }
  }

  private func readExact(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: min(count, 4096))
    while data.count < count {
      let want = min(buffer.count, count - data.count)
      let read = recv(fd, &buffer, want, 0)
      if read < 0 {
        throw SocketError.io("client recv failed: errno \(errno)")
      }
      if read == 0 {
        throw SocketError.io("client closed during handshake")
      }
      data.append(contentsOf: buffer[0..<read])
    }
    return data
  }

  private func writeAll(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes {
        send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
      }
      if written <= 0 {
        throw SocketError.io("client send failed: errno \(errno)")
      }
      offset += written
    }
  }
}

private func hexPrefix(_ data: Data, limit: Int = 24) -> String {
  data.prefix(limit).map { String(format: "%02x", $0) }.joined()
}
