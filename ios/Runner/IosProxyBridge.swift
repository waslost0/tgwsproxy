import Flutter
import UIKit

/// Android-compatible Method/EventChannel boundary for the shared Flutter UI.
/// Packet traffic stays inside the extension; this only controls the profile.
final class IosProxyBridge: NSObject, FlutterStreamHandler {
  private let manager: TunnelManager
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var timer: Timer?
  private var lastLogLine = ""

  init(messenger: FlutterBinaryMessenger, manager: TunnelManager) {
    self.manager = manager
    methods = FlutterMethodChannel(
      name: "com.example.tgwsproxy/proxy",
      binaryMessenger: messenger
    )
    events = FlutterEventChannel(
      name: "com.example.tgwsproxy/proxy_events",
      binaryMessenger: messenger
    )
    super.init()
    methods.setMethodCallHandler(handle)
    events.setStreamHandler(self)
  }

  func dispose() {
    timer?.invalidate()
    timer = nil
    methods.setMethodCallHandler(nil)
    events.setStreamHandler(nil)
  }

  private func complete(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getBootstrap":
      manager.status { outcome in
        switch outcome {
        case .success(let state): self.complete(result, self.bootstrap(state))
        case .failure(let error): self.complete(result, self.flutterError(error))
        }
      }
    case "getState", "getStats":
      manager.status { self.complete(result, self.reply($0)) }
    case "start":
      manager.start { self.complete(result, self.reply($0)) }
    case "stop":
      manager.stop { self.complete(result, self.reply($0)) }
    case "restart":
      manager.restart { self.complete(result, self.reply($0)) }
    case "updateSettings":
      let values = (call.arguments as? [String: Any]) ?? [:]
      manager.updateSettings(values)
      manager.status { state in
        if case .success(let map) = state, map["running"] as? Bool == true {
          self.manager.restart { self.complete(result, self.reply($0)) }
        } else {
          self.complete(result, self.reply(state))
        }
      }
    case "getSecret":
      self.complete(result, manager.secret())
    case "acknowledgeSecretMigration":
      manager.acknowledgeSecretMigration()
      self.complete(result, true)
    case "regenerateSecret":
      let secret = manager.regenerateSecret()
      manager.status { state in
        if case .success(let map) = state, map["running"] as? Bool == true {
          self.manager.restart { _ in self.complete(result, secret) }
        } else {
          self.complete(result, secret)
        }
      }
    case "getProxyLink":
      self.complete(result, manager.link())
    case "openInTelegram":
      guard let url = URL(string: manager.link()) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { ok in self.complete(result, ok) }
    case "getLogs", "clearLogs":
      result([])
    case "exportLogs":
      result("")
    case "exportSettings":
      result(self.json(manager.settings.toMap()))
    case "importSettings":
      guard let raw = call.arguments as? String,
            let data = raw.data(using: .utf8),
            let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        result(FlutterError(code: "INVALID_CONFIG", message: "bad JSON", details: nil))
        return
      }
      manager.updateSettings(map)
      result(true)
    case "getDiagnostics":
      let device = UIDevice.current
      result([
        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        "ios": "\(device.systemName) \(device.systemVersion)",
        "device": device.model,
        "abi": "arm64",
        "state": self.stateMap(nil),
      ])
    case "openBatterySettings":
      result(false)
    case "installUpdate":
      result(false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func bootstrap(_ state: [String: Any]) -> [String: Any] {
    [
      "engineVersion": "rust-1.0.0",
      "settings": manager.settings.toMap(),
      "state": stateMap(state),
      "link": manager.link(),
      "secret": manager.secret(),
      "secretMigrated": manager.secretMigrated,
    ]
  }

  private func stateMap(_ source: [String: Any]?) -> [String: Any] {
    let map = source ?? [:]
    return [
      "running": map["running"] as? Bool ?? false,
      "starting": map["starting"] as? Bool ?? false,
      "host": map["host"] as? String ?? manager.settings.host,
      "port": map["port"] as? Int ?? manager.settings.port,
      "activeConnections": map["activeConnections"] as? Int ?? 0,
      "totalConnections": map["totalConnections"] as? Int ?? 0,
      "bytesUp": map["bytesUp"] as? Int ?? 0,
      "bytesDown": map["bytesDown"] as? Int ?? 0,
      "ws": map["ws"] as? Int ?? 0,
      "cf": map["cf"] as? Int ?? 0,
      "tcpFallback": map["tcpFallback"] as? Int ?? 0,
      "route": map["route"] as? String ?? "",
      "coreVersion": "rust-1.0.0",
    ]
  }

  private func reply(_ outcome: Result<[String: Any], Error>) -> Any? {
    switch outcome {
    case .success(let state): return stateMap(state)
    case .failure(let error): return flutterError(error)
    }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    FlutterError(code: "IOS_TUNNEL", message: error.localizedDescription, details: nil)
  }

  private func json(_ map: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: map),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.manager.status { outcome in
        if case .success(let state) = outcome {
          var event = self.stateMap(state)
          event["type"] = "state"
          self.sink?(event)
          if let log = state["relayLog"] as? String,
             let line = log.split(separator: "\n").last.map(String.init),
             line != self.lastLogLine {
            self.lastLogLine = line
            self.sink?(["type": "log", "level": "info", "line": line])
          }
        }
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    sink = nil
    return nil
  }
}
