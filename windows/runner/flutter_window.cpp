#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  usage_collector_ = std::make_unique<UsageCollector>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Created after SetChildContent so that a window shown by the shell (tray
  // unavailable at a --background start) already hosts the Flutter view.
  app_shell_ = std::make_unique<AppShell>(
      flutter_controller_->engine()->messenger(), GetHandle(), start_hidden_,
      usage_collector_.get(), [this]() {
        if (flutter_controller_) {
          flutter_controller_->ForceRedraw();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // --background: keep the window hidden; it is opened from the tray.
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Removes the tray icon, kills the quit timer and the channel handler.
  app_shell_ = nullptr;

  // Stops the timer, unregisters session notifications and removes the
  // channel handler while the window and the engine are still alive.
  usage_collector_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The app shell goes first: in background mode it turns WM_CLOSE into
  // "hide" before Flutter's HandleTopLevelWindowProc can start an exit
  // request. It also consumes its tray callback, TaskbarCreated, its quit
  // message and quit timer. A handled message may have destroyed the window
  // (and the shell), so only the returned value is used.
  if (app_shell_) {
    std::optional<LRESULT> shell_result =
        app_shell_->HandleWindowMessage(hwnd, message, wparam, lparam);
    if (shell_result) {
      return *shell_result;
    }
  }

  // The usage collector consumes only its own WM_TIMER; session and power
  // notifications are observed and then passed on as usual.
  if (usage_collector_) {
    std::optional<LRESULT> collector_result =
        usage_collector_->HandleWindowMessage(hwnd, message, wparam, lparam);
    if (collector_result) {
      return *collector_result;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
