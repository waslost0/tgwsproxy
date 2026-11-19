import Foundation
import NetworkExtension
import UIKit

/// Owns the VPN profile and exposes the Android-compatible bridge state.
final class TunnelManager {
  typealias Reply = (Result<[String: Any], Error>) -> Void

  private let providerBundleIdentifier = "com.whitetigersoft.tgwsproxy.tunnel"
  private let appGroup = AppGroup.identifier
  private(set) var settings = IosProxySettings.load()

  func reloadSettings() {
    settings = IosProxySettings.load()
  }

  func updateSettings(_ values: [String: Any]) {
    settings.update(values)
    settings.save()
  }

  func regenerateSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let secret = bytes.map { String(format: "%02x", $0) }.joined()
    settings.secret = secret
    settings.secretMigrated = nil
    settings.save()
    return secret
  }

  var secretMigrated: Bool { settings.secretMigrated == true }

  func acknowledgeSecretMigration() {
    settings.secretMigrated = nil
    settings.save()
  }

  func secret() -> String {
    if settings.secret.count != 32 {
      return regenerateSecret()
    }
    return settings.secret
  }

  func link() -> String {
    let prefix = settings.fakeTlsDomain.isEmpty
      ? "dd\(secret())"
      : "ee\(secret())" + settings.fakeTlsDomain.utf8
        .map { String(format: "%02x", $0) }.joined()
    return "tg://proxy?server=\(settings.host)&port=\(settings.port)&secret=\(prefix)"
  }

  func status(completion: @escaping Reply) {
    loadManager { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let manager):
        completion(.success(self.describe(manager)))
      }
    }
  }

  func start(completion: @escaping Reply) {
    reloadSettings()
    loadManager { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let manager):
        self.configure(manager)
        manager.isEnabled = true
        manager.saveToPreferences { error in
          if let error {
            completion(.failure(error))
            return
          }
          manager.loadFromPreferences { error in
            if let error {
              completion(.failure(error))
              return
            }
            do {
              try manager.connection.startVPNTunnel()
              completion(.success(self.describe(manager)))
            } catch {
              completion(.failure(error))
            }
          }
        }
      }
    }
  }

  func restart(completion: @escaping Reply) {
    stop { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        self.start(completion: completion)
      }
    }
  }

  func stop(completion: @escaping Reply) {
    loadManager { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let manager):
        manager.connection.stopVPNTunnel()
        completion(.success(self.describe(manager)))
      }
    }
  }

  private func loadManager(
    completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void
  ) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error {
        completion(.failure(error))
        return
      }
      if let manager = managers?.first(where: { manager in
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?
          .providerBundleIdentifier == self.providerBundleIdentifier
      }) {
        completion(.success(manager))
        return
      }

      let manager = NETunnelProviderManager()
      manager.protocolConfiguration = self.makeProtocol()
      manager.localizedDescription = "TG WS Proxy"
      manager.isEnabled = true
      completion(.success(manager))
    }
  }

  private func configure(_ manager: NETunnelProviderManager) {
    if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
      proto.serverAddress = settings.host
      proto.providerConfiguration = settings.engineConfiguration()
    } else {
      manager.protocolConfiguration = makeProtocol()
    }
  }

  private func makeProtocol() -> NETunnelProviderProtocol {
    let proto = NETunnelProviderProtocol()
    proto.providerBundleIdentifier = providerBundleIdentifier
    proto.serverAddress = settings.host
    proto.providerConfiguration = settings.engineConfiguration()
    return proto
  }

  private func describe(_ manager: NETunnelProviderManager) -> [String: Any] {
    let status = statusName(manager.connection.status)
    let log = relayLogTail()
    let stats = parseStats(log)
    let running = status == "connected"
    let starting = status == "connecting" || status == "reasserting"
    return [
      "status": status,
      "running": running,
      "starting": starting,
      "host": settings.host,
      "port": settings.port,
      "botApiPort": settings.botApiPort,
      "botApiError": settings.botApiEnabled ? "недоступно на iOS" : NSNull(),
      "activeConnections": stats["active"] ?? 0,
      "totalConnections": stats["total"] ?? 0,
      "bytesUp": stats["up"] ?? 0,
      "bytesDown": stats["down"] ?? 0,
      "ws": stats["ws"] ?? 0,
      "cf": stats["cf"] ?? 0,
      "tcpFallback": stats["tcp"] ?? 0,
      "route": route(stats),
      "error": NSNull(),
      "coreVersion": "rust-1.0.0",
      "link": link(),
      "secret": secret(),
      "domain": settings.domain,
      "relayLog": log,
      "stats": stats,
      "settings": settings.toMap(),
    ]
  }

  private func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid: return "invalid"
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .reasserting: return "reasserting"
    case .disconnecting: return "disconnecting"
    @unknown default: return "unknown"
    }
  }

  private func relayLogTail() -> String {
    let text = UserDefaults(suiteName: appGroup)?
      .string(forKey: "relay_log") ?? ""
    return String(text.suffix(6000))
  }

  private func parseStats(_ log: String) -> [String: Int] {
    guard let line = log.split(separator: "\n").last(where: {
      $0.contains("rust stats")
    }) else { return [:] }
    var result: [String: Int] = [:]
    for token in line.split(separator: " ") {
      let parts = token.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let key = String(parts[0])
      let value = String(parts[1])
        .replacingOccurrences(of: "KB", with: "")
        .replacingOccurrences(of: "B", with: "")
      if key == "up_bytes" { result["up"] = Int(value) ?? 0 }
      if key == "down_bytes" { result["down"] = Int(value) ?? 0 }
      if key == "active" { result["active"] = Int(value) ?? 0 }
      if key == "total" { result["total"] = Int(value) ?? 0 }
      if key == "ws" { result["ws"] = Int(value) ?? 0 }
      if key == "cf" { result["cf"] = Int(value) ?? 0 }
      if key == "tcp_fb" { result["tcp"] = Int(value) ?? 0 }
    }
    return result
  }

  private func route(_ stats: [String: Int]) -> String {
    if (stats["cf"] ?? 0) > 0 { return "Cloudflare" }
    if (stats["ws"] ?? 0) > 0 { return "WebSocket" }
    if (stats["tcp"] ?? 0) > 0 { return "TCP fallback" }
    return ""
  }
}
