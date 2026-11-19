import Darwin
import NetworkExtension
import os.log

/// Packet tunnel host for the Rust relay. The Rust core binds the loopback
/// listener itself, so no Swift NWListener is needed.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let log = OSLog(
    subsystem: "com.whitetigersoft.tgwsproxy.tunnel",
    category: "tunnel"
  )
  private let queue = DispatchQueue(label: "com.whitetigersoft.tgwsproxy.tunnel")
  private var statsTimer: DispatchSourceTimer?

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let config = (protocolConfiguration as? NETunnelProviderProtocol)?
      .providerConfiguration ?? [:]
    let port = (config["port"] as? NSNumber)?.uint16Value ?? 1443

    queue.async { [weak self] in
      guard let self else { return }
      self.redirectRustStderr()
      do {
        // The reference project starts the relay before installing tunnel
        // settings; the listener then lives in the extension's network context.
        try NativeProxy.start(configuration: config)
        os_log("rust relay started on 127.0.0.1:%d", log: self.log,
               type: .info, port)
        self.startStatsLogging(port: port)
      } catch {
        os_log("rust relay failed: %{public}@", log: self.log,
               type: .error, error.localizedDescription)
        completionHandler(error)
        return
      }

      let settings = NEPacketTunnelNetworkSettings(
        tunnelRemoteAddress: "127.0.0.1"
      )
      let ipv4 = NEIPv4Settings(
        addresses: ["10.7.0.2"],
        subnetMasks: ["255.255.255.255"]
      )
      ipv4.includedRoutes = []
      ipv4.excludedRoutes = [NEIPv4Route.default()]
      settings.ipv4Settings = ipv4
      settings.mtu = 1500

      self.setTunnelNetworkSettings(settings) { error in
        if let error {
          NativeProxy.stop()
          os_log("tunnel settings failed: %{public}@", log: self.log,
                 type: .error, error.localizedDescription)
          completionHandler(error)
          return
        }
        completionHandler(nil)
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    statsTimer?.cancel()
    statsTimer = nil
    NativeProxy.stop()
    completionHandler()
  }

  /// Sends Rust's `eprintln!` diagnostics to the App Group so they can be
  /// copied over USB; the system log drops provider stderr on iOS.
  private func redirectRustStderr() {
    guard let dir = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.whitetigersoft.tgwsproxy"
    ) else { return }
    let path = dir.appendingPathComponent("rust.log").path
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
      dup2(fd, STDERR_FILENO)
      close(fd)
    }
  }

  /// Rust only writes to stderr, which is not available over USB. Mirror the
  /// native counters into the App Group log so a real client can be verified.
  private func startStatsLogging(port: UInt16) {
    statsTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 2)
    timer.setEventHandler {
      RelayLog.write("rust stats port=\(port) \(NativeProxy.stats()) cfDomains=\(NativeProxy.cfDomains().replacingOccurrences(of: "\n", with: ","))")
    }
    timer.resume()
    statsTimer = timer
  }
}
