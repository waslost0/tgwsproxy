import Foundation
import Security

/// Persistent iOS proxy settings. Android keeps the same keys in DataStore;
/// on iOS the App Group defaults are the single source of truth for the app
/// and the packet-tunnel extension.
struct IosProxySettings: Codable {
  var host = "127.0.0.1"
  var port = 1443
  var dcRedirects: [String: String] = [
    "2": "149.154.167.220",
    "4": "149.154.167.220",
  ]
  var poolSize = 4
  var cfproxyEnabled = true
  var cfUserDomains: [String] = []
  var cfWorkerDomains: [String] = []
  var cfWorkerEnabled = false
  var fakeTlsDomain = ""
  var forceTestDc = false
  var noSecure = true
  var proxyProtocol = false
  var botApiEnabled = false
  var botApiPort = 8081
  var autoStart = true
  var checkUpdates = true
  var domain = "wts-tbss-test.ru"
  var secret = ""
  /// Set once when the publicly known legacy secret was replaced.
  var secretMigrated: Bool?

  static let key = "ios_proxy_settings"
  static let legacySecret = "e6472c7872a569823465f0186d4e62b0"

  static func load() -> IosProxySettings {
    let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    guard
      let data = defaults.data(forKey: key),
      var value = try? JSONDecoder().decode(IosProxySettings.self, from: data)
    else {
      var fresh = IosProxySettings()
      fresh.secret = generatedSecret()
      fresh.save()
      return fresh
    }
    if value.secret.lowercased() == legacySecret {
      value.secret = generatedSecret()
      value.secretMigrated = true
      value.save()
    } else if !isValidSecret(value.secret) {
      value.secret = generatedSecret()
      value.save()
    }
    return value
  }

  /// 16 random bytes as hex; UUID is a safe fallback if the RNG fails.
  static func generatedSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func isValidSecret(_ value: String) -> Bool {
    value.count == 32 && value.allSatisfy(\.isHexDigit)
  }

  func save() {
    let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.key)
      defaults.synchronize()
    }
  }

  func dcIps() -> String {
    dcRedirects
      .compactMap { key, value in
        guard Int(key) != nil, !value.isEmpty else { return nil }
        return "\(key):\(value)"
      }
      .sorted()
      .joined(separator: ",")
  }

  func toMap() -> [String: Any] {
    [
      "host": host,
      "port": port,
      "dcRedirects": dcRedirects,
      "poolSize": poolSize,
      "cfproxyEnabled": cfproxyEnabled,
      "cfUserDomains": cfUserDomains,
      "cfWorkerDomains": cfWorkerDomains,
      "cfWorkerEnabled": cfWorkerEnabled,
      "fakeTlsDomain": fakeTlsDomain,
      "forceTestDc": forceTestDc,
      "noSecure": noSecure,
      "proxyProtocol": proxyProtocol,
      "botApiEnabled": botApiEnabled,
      "botApiPort": botApiPort,
      "autoStart": autoStart,
      "checkUpdates": checkUpdates,
      "domain": domain,
      "platform": "ios",
    ]
  }

  mutating func update(_ values: [String: Any]) {
    if let value = values["host"] as? String, !value.isEmpty { host = value }
    if let value = values["port"] as? Int { port = value }
    if let value = values["port"] as? NSNumber { port = value.intValue }
    if let value = values["dcRedirects"] {
      if let map = value as? [String: String] {
        dcRedirects = map
      } else if let map = value as? [String: Any] {
        dcRedirects = map.mapValues { "\($0)" }
      } else if let map = value as? [AnyHashable: Any] {
        dcRedirects = Dictionary(uniqueKeysWithValues: map.map {
          ("\($0.key)", "\($0.value)")
        })
      }
    }
    if let value = values["poolSize"] as? Int {
      poolSize = min(16, max(1, value))
    } else if let value = values["poolSize"] as? NSNumber {
      poolSize = min(16, max(1, value.intValue))
    }
    if let value = values["cfproxyEnabled"] as? Bool {
      cfproxyEnabled = value
    }
    if let value = values["cfWorkerEnabled"] as? Bool {
      cfWorkerEnabled = value
    }
    if let value = values["fakeTlsDomain"] as? String {
      fakeTlsDomain = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let value = values["forceTestDc"] as? Bool { forceTestDc = value }
    if let value = values["noSecure"] as? Bool { noSecure = value }
    if let value = values["proxyProtocol"] as? Bool { proxyProtocol = value }
    if let value = values["botApiEnabled"] as? Bool { botApiEnabled = value }
    if let value = values["botApiPort"] as? Int { botApiPort = value }
    if let value = values["autoStart"] as? Bool { autoStart = value }
    if let value = values["checkUpdates"] as? Bool { checkUpdates = value }
    if let value = values["domain"] as? String {
      domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    if let value = values["cfUserDomains"] {
      cfUserDomains = Self.strings(value)
    }
    if let value = values["cfWorkerDomains"] {
      cfWorkerDomains = Self.strings(value)
    }
  }

  func engineConfiguration() -> [String: Any] {
    [
      "host": host,
      "port": port,
      "dcIps": dcIps(),
      "secret": secret,
      "domain": domain,
      "poolSize": poolSize,
      "cfproxyEnabled": cfproxyEnabled,
      "cfWorkerDomains": cfWorkerDomains,
      "fakeTlsDomain": fakeTlsDomain,
      "forceTestDc": forceTestDc,
      "noSecure": noSecure,
      "proxyProtocol": proxyProtocol,
    ]
  }

  private static func strings(_ value: Any) -> [String] {
    if let list = value as? [String] {
      return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    if let list = value as? [Any] {
      return list.map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    return "\(value)".split(whereSeparator: { ",; ".contains($0) })
      .map(String.init)
      .filter { !$0.isEmpty }
  }
}

enum AppGroup {
  static let identifier = "group.com.whitetigersoft.tgwsproxy"
}
