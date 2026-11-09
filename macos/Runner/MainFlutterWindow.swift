import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var usageCollectorChannel: UsageCollectorChannel?
  private var fileSaveChannel: FileSaveChannel?
  private var appShellChannel: AppShellChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    (NSApp.delegate as? AppDelegate)?.registerSettingsChannel(
      messenger: flutterViewController.engine.binaryMessenger
    )
    usageCollectorChannel = UsageCollectorChannel(
      messenger: flutterViewController.engine.binaryMessenger
    )
    fileSaveChannel = FileSaveChannel(
      messenger: flutterViewController.engine.binaryMessenger
    )
    appShellChannel = AppShellChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self
    )

    super.awakeFromNib()
  }

  /// Close button and Cmd+W. In background mode the window is hidden
  /// (`orderOut`) instead of closed; the app keeps running in the menu bar.
  /// Cmd+Q / Dock "Quit" do not go through here and still quit the app.
  override func performClose(_ sender: Any?) {
    if appShellChannel?.interceptWindowClose() == true {
      return
    }
    super.performClose(sender)
  }
}
