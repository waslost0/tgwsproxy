import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var menuBar: MenuBarController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    menuBar = MenuBarController(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self
    )

    super.awakeFromNib()
  }
}

/// Status bar item that mirrors the in-process proxy state and drives it
/// through the same Dart repository as the window UI.
final class MenuBarController: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private let statusItem = NSStatusBar.system.statusItem(
    withLength: NSStatusItem.squareLength
  )
  private let statusMenuItem = NSMenuItem(title: "Прокси выключен", action: nil, keyEquivalent: "")
  private let toggleMenuItem = NSMenuItem(title: "Подключить", action: nil, keyEquivalent: "")
  private let copyMenuItem = NSMenuItem(title: "Скопировать ссылку", action: nil, keyEquivalent: "")
  private var link = ""

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(
      name: "com.whitetigersoft.tgwsproxy/menu",
      binaryMessenger: messenger
    )
    self.window = window
    super.init()

    configureStatusItem()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "state", let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.applyState(args)
      result(nil)
    }

    // Dart registers its handler after the engine starts; ask for the state
    // once the first frame has had time to install it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.channel.invokeMethod("sync", arguments: nil)
    }
  }

  private func configureStatusItem() {
    let menu = NSMenu()

    statusMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)
    menu.addItem(.separator())

    toggleMenuItem.target = self
    toggleMenuItem.action = #selector(toggleProxy)
    menu.addItem(toggleMenuItem)

    let telegram = NSMenuItem(
      title: "Открыть Telegram",
      action: #selector(openTelegram),
      keyEquivalent: ""
    )
    telegram.target = self
    menu.addItem(telegram)

    copyMenuItem.target = self
    copyMenuItem.action = #selector(copyLink)
    copyMenuItem.isEnabled = false
    menu.addItem(copyMenuItem)

    menu.addItem(.separator())

    let openApp = NSMenuItem(
      title: "Открыть приложение",
      action: #selector(openApp),
      keyEquivalent: ""
    )
    openApp.target = self
    menu.addItem(openApp)

    let quit = NSMenuItem(
      title: "Выход",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quit.target = self
    menu.addItem(quit)

    statusItem.menu = menu
    if let icon = NSApp.applicationIconImage?.copy() as? NSImage {
      icon.size = NSSize(width: 18, height: 18)
      icon.isTemplate = false
      statusItem.button?.image = icon
    } else {
      statusItem.button?.title = "TG"
    }
    statusItem.button?.toolTip = "TG WS Proxy"
  }

  private func applyState(_ args: [String: Any]) {
    let running = args["running"] as? Bool ?? false
    let starting = args["starting"] as? Bool ?? false
    let port = args["port"] as? Int ?? 1443
    link = args["link"] as? String ?? ""

    if starting {
      statusMenuItem.title = "Запуск…"
    } else if running {
      statusMenuItem.title = "Прокси включён :\(port)"
    } else {
      statusMenuItem.title = "Прокси выключен"
    }
    toggleMenuItem.title = running ? "Отключить" : "Подключить"
    toggleMenuItem.isEnabled = !starting
    copyMenuItem.isEnabled = !link.isEmpty
  }

  @objc private func toggleProxy() {
    channel.invokeMethod("toggle", arguments: nil)
  }

  @objc private func openTelegram() {
    channel.invokeMethod("openTelegram", arguments: nil)
  }

  @objc private func copyLink() {
    guard !link.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(link, forType: .string)
  }

  @objc private func openApp() {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
