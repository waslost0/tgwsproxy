import Foundation

/// Shared diagnostic log for the extension. os_log is hard to read over USB
/// on iOS 18, so the relay writes into the app-group defaults as well as a
/// small file. The app group plist can be copied off the device with
/// `xcrun devicectl device copy from`.
final class RelayLog {
  static let shared = RelayLog()

  static let appGroup = "group.com.whitetigersoft.tgwsproxy"
  private let lock = NSLock()
  private let defaults = UserDefaults(suiteName: appGroup)
  private let url: URL?

  private init() {
    url = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
      .appendingPathComponent("relay.log")
  }

  func write(_ message: String) {
    lock.lock()
    defer { lock.unlock() }

    let line = "\(Self.stamp()) \(message)\n"

    // Defaults work even when the shared container URL is unavailable.
    var text = defaults?.string(forKey: "relay_log") ?? ""
    text += line
    if text.count > 12_000 {
      text = String(text.suffix(8_000))
    }
    defaults?.set(text, forKey: "relay_log")
    defaults?.synchronize()

    guard let url, let bytes = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
      try? bytes.write(to: url)
      return
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: bytes)
  }

  static func write(_ message: String) {
    shared.write(message)
  }

  static func tail(_ limit: Int = 6000) -> String {
    let text = UserDefaults(suiteName: appGroup)?.string(forKey: "relay_log") ?? ""
    return String(text.suffix(limit))
  }

  private static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
  }
}
