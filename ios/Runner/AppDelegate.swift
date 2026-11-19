import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var tunnelManager: TunnelManager?
  private var proxyBridge: IosProxyBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "IosTunnelPlugin"
    ) else {
      return
    }
    let manager = TunnelManager()
    tunnelManager = manager
    proxyBridge = IosProxyBridge(
      messenger: registrar.messenger(),
      manager: manager
    )
    if ProcessInfo.processInfo.arguments.contains("--tgws-autostart") {
      manager.start { _ in }
    }
    let channel = FlutterMethodChannel(
      name: "com.whitetigersoft.tgwsproxy/ios_tunnel",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        manager.status { self.reply(result, $0) }
      case "start":
        manager.start { self.reply(result, $0) }
      case "stop":
        manager.stop { self.reply(result, $0) }
      case "restart":
        manager.restart { self.reply(result, $0) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    if CommandLine.arguments.contains("--tgws-restart") {
      manager.restart { _ in }
    }
  }

  private func reply(
    _ result: @escaping FlutterResult,
    _ outcome: Result<[String: Any], Error>
  ) {
    DispatchQueue.main.async {
      switch outcome {
      case .success(let map):
        result(map)
      case .failure(let error):
        result(FlutterError(
          code: "IOS_TUNNEL",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }
}
