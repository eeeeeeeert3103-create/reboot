import Cocoa
import FlutterMacOS
import ServiceManagement

/// Channel `reboot/app` (docs/app-shell-contract.md, v1): background mode,
/// menu bar item and launch at login.
///
/// Privacy: no network, no input monitoring, no screenshots. While background
/// mode is on, a menu bar item is always visible, so the app never runs hidden.
final class AppShellChannel: NSObject {
  /// The single instance, used by `AppDelegate` and `MainFlutterWindow`.
  private(set) static weak var shared: AppShellChannel?

  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  private(set) var backgroundMode = false
  private var statusItem: NSStatusItem?
  private var statusTitle = ""
  private var statusLines: [String] = []
  private var collecting = true
  private var activity: NSObjectProtocol?
  private var quitSafetyTimer: Timer?
  private var quitting = false

  /// Delay before the app quits anyway after the menu item "Завершить REBOOT".
  static let quitSafetyDelay: TimeInterval = 4
  /// Delay before a hard exit when a graceful terminate did not finish.
  static let hardExitDelay: TimeInterval = 5

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(name: "reboot/app", binaryMessenger: messenger)
    self.window = window
    super.init()
    AppShellChannel.shared = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    endActivity()
  }

  // MARK: - Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "getAppState":
      result(stateMap())
    case "setBackgroundMode":
      guard let enabled = args?["enabled"] as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Нужен параметр enabled.", details: nil))
        return
      }
      setBackgroundMode(enabled)
      result(stateMap())
    case "setLaunchAtLogin":
      guard let enabled = args?["enabled"] as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Нужен параметр enabled.", details: nil))
        return
      }
      if let error = setLaunchAtLogin(enabled) {
        result(FlutterError(code: "launch_at_login_failed", message: error, details: nil))
      } else {
        result(stateMap())
      }
    case "updateStatus":
      let title = (args?["title"] as? String) ?? ""
      let lines = ((args?["lines"] as? [Any]) ?? []).compactMap { $0 as? String }
      let collectingValue = (args?["collecting"] as? Bool) ?? collecting
      updateStatus(title: title, lines: lines, collecting: collectingValue)
      result(nil)
    case "showWindow":
      showWindow()
      result(nil)
    case "hideWindow":
      hideWindow()
      result(nil)
    case "getFrontmostApp":
      result(frontmostApp().map { ["appIdentifier": $0.identifier, "displayName": $0.displayName] })
    case "limitApp":
      guard let identifier = args?["appIdentifier"] as? String, !identifier.isEmpty else {
        result(FlutterError(code: "invalid_arguments", message: "Нужен параметр appIdentifier.", details: nil))
        return
      }
      let outcome = limitApp(identifier)
      result(["applied": outcome.applied, "message": outcome.message])
    case "quit":
      result(nil)
      // Reply first, then terminate on the next run loop pass.
      DispatchQueue.main.async { [weak self] in self?.quitNow() }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - State

  func stateMap() -> [String: Any] {
    let login = launchAtLoginState()
    return [
      "backgroundMode": backgroundMode,
      "windowVisible": window?.isVisible ?? false,
      "launchAtLogin": login.registered,
      "launchAtLoginStatus": login.status,
      "launchAtLoginMessage": login.message,
      "startedInBackground": false,
      "trayAvailable": true,
    ]
  }

  // MARK: - Background mode

  func setBackgroundMode(_ enabled: Bool) {
    guard enabled != backgroundMode else { return }
    backgroundMode = enabled
    if enabled {
      installStatusItem()
      beginActivity()
    } else {
      // Never leave the process running without a window or an icon.
      if !(window?.isVisible ?? false) {
        showWindow()
      }
      removeStatusItem()
      endActivity()
      NSApp.setActivationPolicy(.regular)
    }
  }

  /// Called by `MainFlutterWindow` for the close button and Cmd+W.
  /// Returns true when the window was hidden instead of closed.
  func interceptWindowClose() -> Bool {
    guard backgroundMode, !quitting else { return false }
    hideWindow()
    return true
  }

  func showWindow() {
    guard let window = window else { return }
    let wasVisible = window.isVisible
    NSApp.setActivationPolicy(.regular)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if !wasVisible {
      channel.invokeMethod("windowVisibilityChanged", arguments: ["visible": true])
    }
  }

  func hideWindow() {
    // Hiding only makes sense while the menu bar item exists.
    guard backgroundMode, let window = window, window.isVisible else { return }
    window.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    channel.invokeMethod("windowVisibilityChanged", arguments: ["visible": false])
  }

  private func beginActivity() {
    guard activity == nil else { return }
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "REBOOT собирает статистику"
    )
  }

  private func endActivity() {
    if let activity = activity {
      ProcessInfo.processInfo.endActivity(activity)
    }
    activity = nil
  }

  // MARK: - Menu bar

  func updateStatus(title: String, lines: [String], collecting: Bool) {
    statusTitle = String(title.prefix(16))
    statusLines = Array(lines.prefix(4)).map { String($0.prefix(80)) }
    self.collecting = collecting
    refreshStatusItem()
  }

  private func installStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "REBOOT")
      image?.isTemplate = true
      button.image = image
      button.imagePosition = .imageLeading
      button.toolTip = "REBOOT"
    }
    statusItem = item
    refreshStatusItem()
  }

  private func removeStatusItem() {
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
    }
    statusItem = nil
  }

  private func refreshStatusItem() {
    guard let item = statusItem else { return }
    item.button?.title = statusTitle.isEmpty ? "" : " \(statusTitle)"
    item.menu = buildMenu()
  }

  /// Menu layout from the contract. Exposed for smoke tests.
  func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let lines = statusLines.isEmpty ? ["REBOOT"] : statusLines
    for line in lines {
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("Открыть REBOOT", #selector(openFromMenu)))
    menu.addItem(menuItem(collecting ? "Остановить сбор" : "Возобновить сбор", #selector(toggleCollectionFromMenu)))
    menu.addItem(.separator())
    menu.addItem(menuItem("Завершить REBOOT", #selector(quitFromMenu)))
    return menu
  }

  private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = true
    return item
  }

  @objc private func openFromMenu() {
    showWindow()
    channel.invokeMethod("trayAction", arguments: ["action": "open"])
  }

  @objc private func toggleCollectionFromMenu() {
    channel.invokeMethod("trayAction", arguments: ["action": "toggleCollection"])
  }

  @objc private func quitFromMenu() {
    guard !quitting, quitSafetyTimer == nil else { return }
    // Dart saves data and then calls `quit`. If it does not within 4 s, quit anyway.
    quitSafetyTimer = Timer.scheduledTimer(withTimeInterval: AppShellChannel.quitSafetyDelay, repeats: false) { [weak self] _ in
      self?.quitNow()
    }
    channel.invokeMethod("trayAction", arguments: ["action": "quit"]) { [weak self] response in
      // No Dart handler (or it failed): do not wait for the safety net.
      let notImplemented = (response as? NSObject).map { $0 === FlutterMethodNotImplemented } ?? false
      if response is FlutterError || notImplemented {
        self?.quitNow()
      }
    }
  }

  /// Graceful terminate. `NSApp.terminate` goes through FlutterAppDelegate,
  /// which asks Dart (`onExitRequested`) and quits after Dart answers.
  /// If that does not finish, the process exits hard as a last resort.
  func quitNow() {
    quitSafetyTimer?.invalidate()
    quitSafetyTimer = nil
    guard !quitting else { return }
    quitting = true
    Timer.scheduledTimer(withTimeInterval: AppShellChannel.hardExitDelay, repeats: false) { _ in
      exit(0)
    }
    NSApp.terminate(nil)
  }

  // MARK: - App limits (v1.1)

  /// Identifier as in `UsageCollector`: bundle ID, fallback executable name.
  static func identifier(of app: NSRunningApplication) -> String? {
    let bundleId = app.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    let executable = app.executableURL?.lastPathComponent
    return bundleId ?? executable.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Foreground app, or nil when there is none or REBOOT itself is frontmost.
  func frontmostApp() -> (identifier: String, displayName: String, app: NSRunningApplication)? {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
          let identifier = AppShellChannel.identifier(of: front) else { return nil }
    if let own = Bundle.main.bundleIdentifier, identifier == own { return nil }
    let name = front.localizedName.flatMap { $0.isEmpty ? nil : $0 } ?? identifier
    return (identifier, name, front)
  }

  /// Soft limit: hides the app only if it is frontmost right now, then shows REBOOT.
  /// Never terminates or force-quits anything.
  func limitApp(_ identifier: String) -> (applied: Bool, message: String) {
    guard let front = frontmostApp(), front.identifier == identifier else {
      return (false, "Приложение сейчас не на переднем плане, ничего не сделано.")
    }
    let hidden = front.app.hide()
    showWindow()
    if hidden {
      return (true, "«\(front.displayName)» скрыто. Оно не закрыто, его можно открыть снова в любой момент.")
    }
    return (false, "macOS не дала скрыть «\(front.displayName)». Окно REBOOT показано поверх.")
  }

  // MARK: - Launch at login

  private func launchAtLoginState() -> (registered: Bool, status: String, message: String) {
    guard #available(macOS 13.0, *) else {
      return (false, "notSupported", "Автозапуск доступен на macOS 13 и новее.")
    }
    switch SMAppService.mainApp.status {
    case .enabled:
      return (true, "enabled", "REBOOT запускается при входе в систему.")
    case .notRegistered:
      return (false, "disabled", "Автозапуск выключен.")
    case .requiresApproval:
      return (true, "requiresApproval", "Нужно разрешить в Системных настройках → Основные → Объекты входа.")
    case .notFound:
      return (false, "error", "macOS не нашла REBOOT для автозапуска. Переместите приложение в папку «Программы» и попробуйте снова.")
    @unknown default:
      return (false, "error", "Не удалось определить состояние автозапуска.")
    }
  }

  /// Returns an error message, or nil on success.
  private func setLaunchAtLogin(_ enabled: Bool) -> String? {
    guard #available(macOS 13.0, *) else {
      return "Автозапуск доступен на macOS 13 и новее."
    }
    let service = SMAppService.mainApp
    do {
      if enabled {
        if service.status != .enabled && service.status != .requiresApproval {
          try service.register()
        }
      } else if service.status == .enabled || service.status == .requiresApproval {
        try service.unregister()
      }
      return nil
    } catch {
      let action = enabled ? "включить" : "выключить"
      return "Не удалось \(action) автозапуск: \(error.localizedDescription)"
    }
  }
}
