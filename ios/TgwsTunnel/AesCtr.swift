import CommonCrypto
import Foundation

/// AES-256-CTR matching the Dart core's 128-bit big-endian counter.
///
/// CommonCrypto has no public CTR mode, so each counter block is encrypted in
/// ECB mode and XORed with the payload. One instance is owned by one pump
/// thread; the streams are never shared between the two bridge directions.
final class AesCtr {
  private let key: [UInt8]
  private var counter: [UInt8]

  init(key: Data, iv: Data) {
    precondition(key.count == 32, "AES-256 key must be 32 bytes")
    precondition(iv.count == 16, "AES-CTR IV must be 16 bytes")
    self.key = [UInt8](key)
    self.counter = [UInt8](iv)
  }

  func process(_ data: Data) -> Data {
    if data.isEmpty { return Data() }
    var input = [UInt8](data)
    var output = [UInt8](repeating: 0, count: input.count)
    var offset = 0
    var keystream = [UInt8](repeating: 0, count: 16)

    while offset < input.count {
      encryptCounter(into: &keystream)
      let block = min(16, input.count - offset)
      for i in 0..<block {
        output[offset + i] = input[offset + i] ^ keystream[i]
      }
      offset += block
      incrementCounter()
    }
    return Data(output)
  }

  /// Consumes keystream without emitting data (obfuscated2 skips 64 bytes).
  func skip(_ count: Int) {
    _ = process(Data(count: count))
  }

  private func encryptCounter(into out: inout [UInt8]) {
    var moved = 0
    let status = key.withUnsafeBytes { keyPtr in
      counter.withUnsafeBytes { counterPtr in
        out.withUnsafeMutableBytes { outPtr in
          CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),
            keyPtr.baseAddress, key.count,
            nil,
            counterPtr.baseAddress, 16,
            outPtr.baseAddress, 16,
            &moved
          )
        }
      }
    }
    if status != CCCryptorStatus(kCCSuccess) || moved != 16 {
      // A failure here would silently corrupt the tunnel; fail loudly.
      fatalError("AES-CTR block encryption failed: \(status)")
    }
  }

  private func incrementCounter() {
    // Big-endian 128-bit increment. The first 8 bytes stay zero in practice,
    // but carrying through the full block keeps the CTR definition exact.
    for index in stride(from: 15, through: 0, by: -1) {
      counter[index] = counter[index] &+ 1
      if counter[index] != 0 { break }
    }
  }
}
