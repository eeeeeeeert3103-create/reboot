import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Channel `reboot/files`: saves text chosen by the user through the system save panel.
/// Access to the chosen file is granted by the sandbox
/// (`com.apple.security.files.user-selected.read-write`).
final class FileSaveChannel {
  private let channel: FlutterMethodChannel
  private var panelOpen = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "reboot/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "saveTextFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let suggestedName = args["suggestedName"] as? String,
          let content = args["content"] as? String else {
      result(FlutterError(code: "invalid_arguments", message: "Нужны suggestedName и content.", details: nil))
      return
    }
    guard !panelOpen else {
      result(FlutterError(code: "busy", message: "Окно сохранения уже открыто.", details: nil))
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    let name = (suggestedName as NSString).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    panel.nameFieldStringValue = name.isEmpty ? "reboot-export.json" : name

    panelOpen = true
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      self?.panelOpen = false
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      let data = Data(content.utf8)
      do {
        do {
          try data.write(to: url, options: .atomic)
        } catch {
          // Fallback in case an atomic replace is not possible at the chosen location.
          try data.write(to: url)
        }
        result(url.path)
      } catch {
        result(FlutterError(code: "write_failed", message: "Не удалось записать файл.", details: error.localizedDescription))
      }
    }

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }
}
