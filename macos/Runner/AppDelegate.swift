import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  func registerSettingsChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "reboot/settings",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      let preferences = UserDefaults.standard
      switch call.method {
      case "loadSettings":
        result([
          "profileName": preferences.string(forKey: "settings.profileName") ?? "Александр Иванов",
          "notifications": preferences.object(forKey: "settings.notifications") as? Bool ?? true,
          "weeklySummary": preferences.object(forKey: "settings.weeklySummary") as? Bool ?? true,
          "goalHours": preferences.object(forKey: "settings.goalHours") as? Double ?? 6.0,
          "themeId": preferences.string(forKey: "settings.themeId") ?? "dark",
        ])
      case "saveSettings":
        guard let settings = call.arguments as? [String: Any],
              let notifications = settings["notifications"] as? Bool,
              let profileName = settings["profileName"] as? String,
              !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profileName.count <= 80,
              let weeklySummary = settings["weeklySummary"] as? Bool,
              let goalHours = settings["goalHours"] as? Double,
              goalHours.isFinite, (2.0...10.0).contains(goalHours),
              let themeId = settings["themeId"] as? String,
              ["dark", "light", "violet", "midnightBlue", "emerald"].contains(themeId) else {
          result(FlutterError(code: "invalid_settings", message: "Invalid settings payload.", details: nil))
          return
        }
        preferences.set(notifications, forKey: "settings.notifications")
        preferences.set(profileName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "settings.profileName")
        preferences.set(weeklySummary, forKey: "settings.weeklySummary")
        preferences.set(goalHours, forKey: "settings.goalHours")
        preferences.set(themeId, forKey: "settings.themeId")
        result(nil)
      case "deleteSettings":
        ["settings.profileName", "settings.notifications", "settings.weeklySummary", "settings.goalHours", "settings.themeId"].forEach {
          preferences.removeObject(forKey: $0)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Background mode (`reboot/app`): the app keeps running with a menu bar item.
    return !(AppShellChannel.shared?.backgroundMode ?? false)
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      AppShellChannel.shared?.showWindow()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
