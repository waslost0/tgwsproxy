import Foundation

// C ABI exported by the Rust core (src/lib.rs). The Rust listener owns the
// loopback socket, MTProto crypto and the Cloudflare WebSocket transport.
@_silgen_name("StartProxy")
private func rustStartProxy(
  _ host: UnsafePointer<CChar>?,
  _ port: Int32,
  _ dcIps: UnsafePointer<CChar>?,
  _ secret: UnsafePointer<CChar>?,
  _ verbose: Int32
) -> Int32

@_silgen_name("StopProxy")
private func rustStopProxy() -> Int32

@_silgen_name("SetPoolSize")
private func rustSetPoolSize(_ size: Int32)

@_silgen_name("SetBufferSizeKb")
private func rustSetBufferSizeKb(_ kb: Int32)

@_silgen_name("SetDisableSecure")
private func rustSetDisableSecure(_ value: Int32)

@_silgen_name("SetForceTestDc")
private func rustSetForceTestDc(_ value: Int32)

@_silgen_name("SetProxyProtocol")
private func rustSetProxyProtocol(_ value: Int32)

@_silgen_name("SetCfProxyCacheDir")
private func rustSetCfProxyCacheDir(_ path: UnsafePointer<CChar>?)

@_silgen_name("SetCfProxyConfig")
private func rustSetCfProxyConfig(
  _ enabled: Int32,
  _ priority: Int32,
  _ userDomain: UnsafePointer<CChar>?
)

@_silgen_name("SetCfWorkerDomains")
private func rustSetCfWorkerDomains(_ domains: UnsafePointer<CChar>?)

@_silgen_name("SetFakeTlsDomain")
private func rustSetFakeTlsDomain(_ domain: UnsafePointer<CChar>?)

@_silgen_name("GetStats")
private func rustGetStats() -> UnsafePointer<CChar>?

@_silgen_name("GetCfProxyDomains")
private func rustGetCfProxyDomains() -> UnsafePointer<CChar>?

@_silgen_name("FreeString")
private func rustFreeString(_ value: UnsafePointer<CChar>?)

private enum AppGroup {
  static let identifier = "group.com.whitetigersoft.tgwsproxy"
}

enum NativeProxyError: LocalizedError {
  case invalidSecret
  case bindFailed

  var errorDescription: String? {
    switch self {
    case .invalidSecret: return "Некорректный секрет MTProto"
    case .bindFailed: return "Не удалось открыть локальный порт прокси"
    }
  }
}

/// Thin Swift facade over the reference Rust relay.
enum NativeProxy {
  static func start(configuration: [String: Any]) throws {
    let secret = configuration["secret"] as? String ?? ""
    guard secret.count == 32, Data(hexString: secret) != nil else {
      throw NativeProxyError.invalidSecret
    }

    let host = configuration["host"] as? String ?? "127.0.0.1"
    let port = (configuration["port"] as? NSNumber)?.int32Value ?? 1443
    var dcIps = configuration["dcIps"] as? String ?? ""
    if dcIps.isEmpty {
      dcIps = "2:149.154.167.220,4:149.154.167.220"
    }
    let domain = configuration["domain"] as? String ?? ""
    let poolSize = (configuration["poolSize"] as? NSNumber)?.int32Value ?? 4
    let noSecure = configuration["noSecure"] as? Bool ?? true
    let cfproxy = configuration["cfproxyEnabled"] as? Bool ?? true
    let fakeTls = configuration["fakeTlsDomain"] as? String ?? ""
    let forceTest = configuration["forceTestDc"] as? Bool ?? false
    let proxyProtocol = configuration["proxyProtocol"] as? Bool ?? false
    let workersEnabled = configuration["cfWorkerEnabled"] as? Bool ?? false
    let workerDomains = workersEnabled
      ? (configuration["cfWorkerDomains"] as? [String] ?? []).joined(separator: ",")
      : ""

    let cache = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
      .appendingPathComponent("cfproxy").path
      ?? NSTemporaryDirectory()

    rustSetPoolSize(poolSize)
    rustSetBufferSizeKb(256)
    rustSetDisableSecure(noSecure ? 1 : 0)
    rustSetForceTestDc(forceTest ? 1 : 0)
    rustSetProxyProtocol(proxyProtocol ? 1 : 0)
    rustSetCfProxyCacheDir(cache)
    rustSetCfWorkerDomains(workerDomains)
    rustSetFakeTlsDomain(fakeTls)
    let cfEnabled: Int32 = cfproxy ? 1 : 0
    let result = domain.withCString { domainPtr in
      rustSetCfProxyConfig(cfEnabled, 1, domainPtr)
      return secret.withCString { secretPtr in
        dcIps.withCString { dcPtr in
          host.withCString { hostPtr in
            rustStartProxy(hostPtr, port, dcPtr, secretPtr, 1)
          }
        }
      }
    }

    if result != 0 {
      throw NativeProxyError.bindFailed
    }
  }

  static func stats() -> String {
    guard let pointer = rustGetStats() else { return "" }
    defer { rustFreeString(pointer) }
    return String(cString: pointer)
  }

  static func cfDomains() -> String {
    guard let pointer = rustGetCfProxyDomains() else { return "" }
    defer { rustFreeString(pointer) }
    return String(cString: pointer)
  }

  static func stop() {
    _ = rustStopProxy()
  }
}

private extension Data {
  init?(hexString: String) {
    guard hexString.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(hexString.count / 2)
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2)
      guard let byte = UInt8(hexString[index..<next], radix: 16) else {
        return nil
      }
      bytes.append(byte)
      index = next
    }
    self = Data(bytes)
  }
}
