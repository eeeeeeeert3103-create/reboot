#ifndef RUNNER_APP_SHELL_H_
#define RUNNER_APP_SHELL_H_

// windows.h must come before any other Windows SDK header (shellapi.h is
// included only in the .cpp file, after windows.h).
#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "usage_collector.h"

// Registered window message (RegisterWindowMessageW) that a second REBOOT
// instance posts to the first instance's top-level window: "show the window".
// Shared by main.cpp (sender) and AppShell (handler).
inline constexpr wchar_t kShowWindowMessageName[] = L"REBOOT.ShowWindow";

// Native application shell for the "reboot/app" method channel
// (docs/app-shell-contract.md, v1 + v1.1): notification area (tray) icon with
// a menu, always-on background mode, launch at login (HKCU Run key),
// --background start, getFrontmostApp and the soft limitApp.
//
// v1.1: the tray icon is shown for the whole lifetime of the process and
// background mode is always on: the close button hides the window to the
// tray. Only "Завершить REBOOT" / Dart "quit" (or Windows shutdown / logoff,
// which is never blocked) ends the process.
//
// Everything runs on the UI thread. FlutterWindow::MessageHandler forwards
// every top-level window message to HandleWindowMessage BEFORE Flutter's
// HandleTopLevelWindowProc, so that WM_CLOSE can be turned into "hide" while
// background mode is on.
//
// Privacy: no network, no hooks, no screenshots. The tray icon is always
// visible while the window is hidden, so the process is never running
// invisibly.
class AppShell {
 public:
  // |window| is the top-level FlutterWindow HWND. |started_in_background| is
  // true when the process was launched with --background (the window was
  // created but never shown). |on_window_shown| is called after the window
  // has been shown again (used to force a Flutter redraw); may be empty.
  // |collector| (not owned, may be null) resolves the foreground app with the
  // collector's identifiers; it must outlive this shell.
  AppShell(flutter::BinaryMessenger* messenger,
           HWND window,
           bool started_in_background,
           UsageCollector* collector,
           std::function<void()> on_window_shown);
  ~AppShell();

  AppShell(const AppShell&) = delete;
  AppShell& operator=(const AppShell&) = delete;

  // Returns a value when the message was fully handled by the shell: WM_CLOSE
  // in background mode, the tray callback message, TaskbarCreated, the
  // second-instance "REBOOT.ShowWindow" message, the
  // shell's own quit message and quit timer. Everything else returns
  // std::nullopt so that normal processing continues.
  //
  // NOTE: when this performs the final quit it calls DestroyWindow, which
  // destroys this AppShell (FlutterWindow::OnDestroy). The caller must not
  // touch the shell after a handled message; it only returns the result.
  std::optional<LRESULT> HandleWindowMessage(HWND hwnd,
                                             UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam);

 private:
  using MethodResultPtr =
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      MethodResultPtr result);

  flutter::EncodableValue BuildState() const;

  // v1.1 app limits.
  flutter::EncodableValue GetFrontmostApp();
  flutter::EncodableValue LimitApp(const std::string& app_identifier);

  // Window visibility.
  bool IsWindowShown() const;
  void ShowMainWindow();
  // Returns false (and leaves the window as is) when no tray icon could be
  // added, so the window never disappears without a way back.
  bool HideMainWindow();
  void NotifyVisibility(bool visible);

  // Tray icon.
  void UpdateTrayIcon();
  bool AddTrayIcon();
  void RemoveTrayIcon();
  // NIM_MODIFY of the tooltip; false when the icon is not (or no longer)
  // there, e.g. while Explorer is restarting. Also used as a probe.
  bool ApplyTooltip();
  void ShowTrayMenu(int x, int y);
  void HandleTrayCallback(WPARAM wparam, LPARAM lparam);

  // Quit flow.
  void SendTrayAction(const char* action);
  void StartQuitSafetyNet();
  // Removes the icon and destroys the window. |this| is deleted when the
  // window is destroyed, so nothing may follow a call to this.
  void PerformQuit(HWND hwnd);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_ = nullptr;
  UsageCollector* collector_ = nullptr;
  std::function<void()> on_window_shown_;

  // Always true on Windows since v1.1; setBackgroundMode is accepted and
  // ignored.
  bool background_mode_ = true;
  bool started_in_background_ = false;
  // True while the window is hidden by the shell (--background start, close
  // button in background mode, hideWindow). The tray icon is always shown
  // while this is true, even if background mode was turned off meanwhile.
  bool hidden_by_shell_ = false;

  // Tray.
  HICON tray_icon_ = nullptr;
  bool owns_tray_icon_ = false;  // false for the shared fallback icon.
  bool icon_added_ = false;
  bool icon_version4_ = false;  // NIM_SETVERSION(NOTIFYICON_VERSION_4) ok.
  bool icon_add_failed_ = false;
  UINT taskbar_created_message_ = 0;
  UINT show_window_message_ = 0;  // kShowWindowMessageName.
  std::wstring tooltip_;
  std::vector<std::wstring> status_lines_;
  bool collecting_ = false;

  // Menu / quit state.
  bool menu_active_ = false;
  bool quit_after_menu_ = false;
  bool quit_timer_active_ = false;
  bool quitting_ = false;
  // Set on WM_QUERYENDSESSION, cleared if the session end is cancelled: a
  // WM_CLOSE during shutdown / logoff (e.g. Restart Manager) is not turned
  // into "hide", so Windows is never blocked.
  bool session_ending_ = false;
};

#endif  // RUNNER_APP_SHELL_H_
