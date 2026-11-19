import CryptoKit
import Foundation
import Security

enum MtProto {
  static let handshakeLen = 64
  static let skipLen = 8
  static let prekeyLen = 32
  static let keyLen = 32
  static let ivLen = 16
  static let protoTagPos = 56
  static let dcIdxPos = 60

  static let tagAbridged: [UInt8] = [0xEF, 0xEF, 0xEF, 0xEF]
  static let tagIntermediate: [UInt8] = [0xEE, 0xEE, 0xEE, 0xEE]
  static let tagPadded: [UInt8] = [0xDD, 0xDD, 0xDD, 0xDD]

  static let reservedStarts: [[UInt8]] = [
    [0x48, 0x45, 0x41, 0x44], // HEAD
    [0x50, 0x4F, 0x53, 0x54], // POST
    [0x47, 0x45, 0x54, 0x20], // GET
    tagIntermediate,
    tagPadded,
    [0x16, 0x03, 0x01, 0x02], // TLS record
    [0x4F, 0x50, 0x54, 0x49], // OPTI
  ]

  static func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  static func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    // Pass the array's element buffer, not the Array struct itself.
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return Data(bytes)
  }

  static func tryHandshake(_ handshake: Data, secret: Data) -> Handshake? {
    guard handshake.count == handshakeLen, secret.count == 16 else { return nil }
    // obfuscated2 skips the first 8 bytes: the key material starts at 8 and
    // spans bytes 8..<56 of the 64-byte client init.
    let prekeyIv = Data(handshake[skipLen..<skipLen + prekeyLen + ivLen])
    let key = sha256(Data(prekeyIv.prefix(prekeyLen)) + secret)
    let iv = Data(prekeyIv[prekeyLen..<prekeyLen + ivLen])
    let decrypted = AesCtr(key: key, iv: iv).process(handshake)
    guard decrypted.count == handshakeLen else { return nil }

    let tag = [UInt8](decrypted[protoTagPos..<protoTagPos + 4])
    guard tag == tagAbridged || tag == tagIntermediate || tag == tagPadded else {
      return nil
    }
    let rawDc = UInt16(decrypted[dcIdxPos]) | (UInt16(decrypted[dcIdxPos + 1]) << 8)
    let dc = Int(Int16(bitPattern: rawDc))
    return Handshake(
      dc: abs(dc),
      media: dc < 0,
      protoTag: tag,
      prekeyIv: Data(prekeyIv)
    )
  }

  /// Builds the 64-byte relay init. The last 8 bytes carry the encrypted
  /// protocol tag and signed DC id; the first 56 bytes are random.
  static func generateRelayInit(protoTag: [UInt8], dcIdx: Int) -> Data {
    precondition(protoTag.count == 4)
    var initBytes = [UInt8](repeating: 0, count: handshakeLen)
    for _ in 0..<100_000 {
      initBytes = [UInt8](randomBytes(handshakeLen))
      if initBytes[0] == 0xEF { continue }
      if reservedStarts.contains(where: { prefix in
        initBytes.count >= prefix.count &&
          Array(initBytes[0..<prefix.count]) == prefix
      }) { continue }
      if initBytes[4] == 0 && initBytes[5] == 0 &&
          initBytes[6] == 0 && initBytes[7] == 0 { continue }
      break
    }

    let key = Data(initBytes[skipLen..<skipLen + prekeyLen])
    let iv = Data(initBytes[skipLen + prekeyLen..<skipLen + prekeyLen + ivLen])
    let keystream = AesCtr(key: key, iv: iv).process(Data(count: handshakeLen))

    let rawDc = UInt16(bitPattern: Int16(dcIdx))
    var tail: [UInt8] = [
      protoTag[0], protoTag[1], protoTag[2], protoTag[3],
      UInt8(rawDc & 0xFF), UInt8(rawDc >> 8),
      randomBytes(1)[0], randomBytes(1)[0],
    ]
    for i in 0..<8 {
      tail[i] ^= keystream[protoTagPos + i]
    }
    initBytes.replaceSubrange(protoTagPos..<protoTagPos + 8, with: tail)
    return Data(initBytes)
  }

  static func buildCryptoContext(
    prekeyIv: Data,
    secret: Data,
    relayInit: Data
  ) -> CryptoContext {
    precondition(prekeyIv.count == 48)
    precondition(secret.count == 16)
    precondition(relayInit.count == 64)

    let clientDecryptKey = sha256(Data(prekeyIv[0..<prekeyLen]) + secret)
    let reversed = Data(prekeyIv.reversed())
    let clientEncryptKey = sha256(Data(reversed[0..<prekeyLen]) + secret)

    let relayEncryptKey = Data(relayInit[skipLen..<skipLen + prekeyLen])
    let relayEncryptIv = Data(
      relayInit[skipLen + prekeyLen..<skipLen + prekeyLen + ivLen]
    )
    let relayDecrypt = Data(
      relayInit[skipLen..<skipLen + prekeyLen + ivLen].reversed()
    )

    let clientDecrypt = AesCtr(
      key: clientDecryptKey,
      iv: Data(prekeyIv[prekeyLen..<prekeyLen + ivLen])
    )
    clientDecrypt.skip(handshakeLen)

    let telegramEncrypt = AesCtr(key: relayEncryptKey, iv: relayEncryptIv)
    telegramEncrypt.skip(handshakeLen)

    return CryptoContext(
      clientDecrypt: clientDecrypt,
      clientEncrypt: AesCtr(
        key: clientEncryptKey,
        iv: Data(reversed[prekeyLen..<prekeyLen + ivLen])
      ),
      telegramEncrypt: telegramEncrypt,
      telegramDecrypt: AesCtr(
        key: Data(relayDecrypt[0..<keyLen]),
        iv: Data(relayDecrypt[keyLen..<keyLen + ivLen])
      )
    )
  }

  static func protoInt(_ tag: [UInt8]) -> UInt32? {
    guard tag.count == 4 else { return nil }
    let value = UInt32(tag[0]) |
      (UInt32(tag[1]) << 8) |
      (UInt32(tag[2]) << 16) |
      (UInt32(tag[3]) << 24)
    return value == 0xEFEFEFEF || value == 0xEEEEEEEE || value == 0xDDDDDDDD
      ? value : nil
  }
}

struct Handshake {
  let dc: Int
  let media: Bool
  let protoTag: [UInt8]
  let prekeyIv: Data
}

struct CryptoContext {
  let clientDecrypt: AesCtr
  let clientEncrypt: AesCtr
  let telegramEncrypt: AesCtr
  let telegramDecrypt: AesCtr
}

/// Splits a decrypted MTProto stream into transport packets. Ciphertext is
/// forwarded unchanged; plaintext is kept only to read packet lengths.
final class MsgSplitter {
  private let proto: UInt32
  private var cipher: [UInt8] = []
  private var plain: [UInt8] = []
  private var disabled = false

  init(proto: UInt32) {
    self.proto = proto
  }

  func split(cipher newCipher: Data, plain newPlain: Data) -> [Data] {
    if newCipher.isEmpty { return [] }
    precondition(newCipher.count == newPlain.count)
    if disabled { return [newCipher] }

    cipher.append(contentsOf: newCipher)
    plain.append(contentsOf: newPlain)
    var parts: [Data] = []
    var offset = 0

    while offset < cipher.count {
      guard let packetLen = nextPacketLen(offset: offset) else { break }
      if packetLen <= 0 {
        parts.append(Data(cipher[offset...]))
        offset = cipher.count
        disabled = true
        break
      }
      parts.append(Data(cipher[offset..<offset + packetLen]))
      offset += packetLen
    }

    if offset > 0 {
      cipher.removeFirst(offset)
      plain.removeFirst(offset)
    }
    return parts
  }

  func flush() -> [Data] {
    guard !cipher.isEmpty else { return [] }
    let tail = Data(cipher)
    cipher.removeAll()
    plain.removeAll()
    return [tail]
  }

  private func nextPacketLen(offset: Int) -> Int? {
    let avail = cipher.count - offset
    if avail <= 0 { return nil }

    if proto == 0xEFEFEFEF {
      let first = plain[offset]
      if first == 0x7F || first == 0xFF {
        if avail < 4 { return nil }
        let payload = (Int(plain[offset + 1]) |
          (Int(plain[offset + 2]) << 8) |
          (Int(plain[offset + 3]) << 16)) * 4
        if payload <= 0 { return 0 }
        let total = 4 + payload
        return avail < total ? nil : total
      }
      let payload = Int(first & 0x7F) * 4
      if payload <= 0 { return 0 }
      let total = 1 + payload
      return avail < total ? nil : total
    }

    if proto == 0xEEEEEEEE || proto == 0xDDDDDDDD {
      if avail < 4 { return nil }
      let payload = (Int(plain[offset]) |
        (Int(plain[offset + 1]) << 8) |
        (Int(plain[offset + 2]) << 16) |
        (Int(plain[offset + 3]) << 24)) & 0x7FFFFFFF
      if payload <= 0 { return 0 }
      let total = 4 + payload
      return avail < total ? nil : total
    }
    return 0
  }
}
