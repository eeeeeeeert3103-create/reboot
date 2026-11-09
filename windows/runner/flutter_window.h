#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "app_shell.h"
#include "usage_collector.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // With |start_hidden| (--background) the window is created and the engine
  // runs, but the window is not shown after the first frame; the tray icon
  // is shown instead (see AppShell).
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // Launched with --background: do not show the window on the first frame.
  bool start_hidden_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Local usage collector on the "reboot/collector" channel. Declared after
  // flutter_controller_ so it is destroyed first; OnDestroy also resets it
  // before the engine (which owns the messenger) goes away.
  std::unique_ptr<UsageCollector> usage_collector_;

  // App shell on the "reboot/app" channel: tray icon, background mode,
  // launch at login. Also reset in OnDestroy before the engine goes away.
  std::unique_ptr<AppShell> app_shell_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
