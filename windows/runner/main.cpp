#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_shell.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// Single-instance mutex in the "Local" namespace (current logon session).
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\REBOOT.SingleInstance.com.reboot.app";
// Class and title of the first instance's top-level window: the class is
// kWindowClassName in win32_window.cpp, the title is passed to Create below.
constexpr wchar_t kMainWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kMainWindowTitle[] = L"reboot_app";

// Asks the already running instance to show its window. The first instance
// may still be starting (mutex taken, window not created yet), so retry for
// up to ~2 s.
void ActivateFirstInstance() {
  const UINT show_message = ::RegisterWindowMessageW(kShowWindowMessageName);
  if (show_message == 0) {
    return;
  }
  for (int attempt = 0; attempt < 20; ++attempt) {
    HWND first = ::FindWindowW(kMainWindowClass, kMainWindowTitle);
    if (first != nullptr) {
      // This process got the foreground from the user's launch; pass the
      // right on so that the first instance's SetForegroundWindow works.
      DWORD first_pid = 0;
      ::GetWindowThreadProcessId(first, &first_pid);
      if (first_pid != 0) {
        ::AllowSetForegroundWindow(first_pid);
      }
      ::PostMessageW(first, show_message, 0, 0);
      return;
    }
    ::Sleep(100);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // "--background" (written by launch at login into HKCU\...\Run): create
  // the window and the engine, but do not show the window; the tray icon is
  // shown instead. The argument is also passed on to Dart unchanged.
  bool start_in_background = false;
  for (const std::string& argument : command_line_arguments) {
    if (argument == "--background") {
      start_in_background = true;
    }
  }

  // Single instance: otherwise launch at login plus a manual start would run
  // two collectors and show two tray icons. The handle is intentionally kept
  // open until the process exits (the OS releases it then).
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // A --background start (login) shows nothing; a normal start brings the
    // running instance's window to the front.
    if (!start_in_background) {
      ActivateFirstInstance();
    }
    ::CloseHandle(single_instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_in_background);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kMainWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
