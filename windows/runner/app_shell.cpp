#include "app_shell.h"

// windows.h is included by app_shell.h; shellapi.h must follow it.
#include <windows.h>
#include <shellapi.h>

#include <flutter/standard_method_codec.h>

#include <cwchar>
#include <string>
#include <utility>
#include <variant>

#include "resource.h"

// Source strings below contain Russian text; the runner is compiled with
// /utf-8 (see runner/CMakeLists.txt), so narrow literals are UTF-8 (sent to
// Dart) and wide literals are UTF-16 (shown by Windows).

namespace {

constexpr char kChannelName[] = "reboot/app";

// Private messages on the top-level FlutterWindow HWND.
constexpr UINT kTrayCallbackMessage = WM_APP + 1;  // Shell_NotifyIcon events.
constexpr UINT kQuitMessage = WM_APP + 2;          // Posted by Dart's "quit".

constexpr UINT kTrayIconId = 1;

// Safety net after trayAction "quit": terminate if Dart has not called "quit".
// Distinct from the collector timer id (0x52424354) on the same HWND.
constexpr UINT_PTR kQuitTimerId = 0x52424151;  // 'RBAQ'
constexpr UINT kQuitTimeoutMs = 4000;

// Tray menu command ids (TrackPopupMenu with TPM_RETURNCMD returns them, so
// no WM_COMMAND is routed through Flutter).
constexpr int kCmdOpen = 1;
constexpr int kCmdToggleCollection = 2;
constexpr int kCmdQuit = 3;
constexpr int kCmdStatusBase = 100;  // Disabled status lines.

constexpr size_t kMaxStatusLines = 4;
constexpr size_t kMaxStatusLineChars = 120;
constexpr size_t kMaxTooltipChars = 127;  // szTip is WCHAR[128].

// Launch at login.
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
// Written by Task Manager / Settings → Apps → Startup when the user turns an
// entry off. Undocumented: the first byte is even (0x02) when enabled and odd
// (0x03) when disabled. Only read, never written.
constexpr wchar_t kStartupApprovedKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved"
    L"\\Run";
constexpr wchar_t kRunValueName[] = L"REBOOT";
constexpr wchar_t kBackgroundArgument[] = L"--background";

struct LaunchAtLoginState {
  bool registered = false;
  std::string status;   // enabled | disabled | requiresApproval | error
  std::string message;  // Short Russian text for the UI.
};

flutter::EncodableValue Str(const std::string& value) {
  return flutter::EncodableValue(value);
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  // Status lines are short; cap the input so the int conversion is safe.
  const size_t capped = utf8.size() < 4096 ? utf8.size() : 4096;
  const int utf8_length = static_cast<int>(capped);
  const int length = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                           utf8_length, nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  const int written = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                            utf8_length, &wide[0], length);
  if (written <= 0) {
    return std::wstring();
  }
  wide.resize(static_cast<size_t>(written));
  return wide;
}

// Truncates to |max_chars| UTF-16 units without splitting a surrogate pair.
std::wstring LimitLength(std::wstring text, size_t max_chars) {
  if (text.size() <= max_chars) {
    return text;
  }
  size_t cut = max_chars;
  if (cut > 0 && text[cut - 1] >= 0xD800 && text[cut - 1] <= 0xDBFF) {
    --cut;
  }
  text.resize(cut);
  return text;
}

// '&' is the mnemonic prefix in menu item text.
std::wstring EscapeMenuText(const std::wstring& text) {
  std::wstring escaped;
  escaped.reserve(text.size());
  for (const wchar_t ch : text) {
    escaped.push_back(ch);
    if (ch == L'&') {
      escaped.push_back(L'&');
    }
  }
  return escaped;
}

bool GetBoolArgument(const flutter::EncodableValue* arguments,
                     const char* key,
                     bool* out) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return false;
  }
  const auto it = map->find(Str(key));
  if (it == map->end()) {
    return false;
  }
  const bool* value = std::get_if<bool>(&it->second);
  if (value == nullptr) {
    return false;
  }
  *out = *value;
  return true;
}

// Full path of the running exe, or empty on failure.
std::wstring GetExecutablePath() {
  std::wstring buffer(static_cast<size_t>(MAX_PATH), L'\0');
  for (int attempt = 0; attempt < 6; ++attempt) {
    const DWORD capacity = static_cast<DWORD>(buffer.size());
    const DWORD length = ::GetModuleFileNameW(nullptr, &buffer[0], capacity);
    if (length == 0) {
      return std::wstring();
    }
    if (length < capacity) {
      buffer.resize(static_cast<size_t>(length));
      return buffer;
    }
    // Truncated (ERROR_INSUFFICIENT_BUFFER): retry with a larger buffer.
    buffer.resize(buffer.size() * 2);
  }
  return std::wstring();
}

// "<full exe path>" --background
std::wstring BuildRunCommand(const std::wstring& exe_path) {
  return L"\"" + exe_path + L"\" " + kBackgroundArgument;
}

bool EqualsIgnoreCase(const std::wstring& a, const std::wstring& b) {
  if (a.size() != b.size()) {
    return false;
  }
  return ::CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()),
                                b.c_str(), static_cast<int>(b.size()),
                                TRUE) == CSTR_EQUAL;
}

// Reads HKCU\...\Run\REBOOT. Returns ERROR_FILE_NOT_FOUND when the value (or
// the key) does not exist.
LSTATUS ReadRunValue(std::wstring* out) {
  for (int attempt = 0; attempt < 3; ++attempt) {
    DWORD size_bytes = 0;
    LSTATUS status =
        ::RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValueName,
                       RRF_RT_REG_SZ, nullptr, nullptr, &size_bytes);
    if (status != ERROR_SUCCESS) {
      return status;
    }
    std::wstring buffer(size_bytes / sizeof(wchar_t) + 1, L'\0');
    DWORD buffer_bytes = static_cast<DWORD>(buffer.size() * sizeof(wchar_t));
    status = ::RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValueName,
                            RRF_RT_REG_SZ, nullptr, &buffer[0],
                            &buffer_bytes);
    if (status == ERROR_MORE_DATA) {
      continue;  // Value changed between the two calls.
    }
    if (status != ERROR_SUCCESS) {
      return status;
    }
    size_t chars = buffer_bytes / sizeof(wchar_t);
    while (chars > 0 && buffer[chars - 1] == L'\0') {
      --chars;
    }
    buffer.resize(chars);
    *out = std::move(buffer);
    return ERROR_SUCCESS;
  }
  return ERROR_MORE_DATA;
}

// True when the user turned the entry off in Task Manager → Startup apps.
bool IsTurnedOffInStartupApps() {
  BYTE data[64] = {};
  DWORD size_bytes = static_cast<DWORD>(sizeof(data));
  const LSTATUS status =
      ::RegGetValueW(HKEY_CURRENT_USER, kStartupApprovedKey, kRunValueName,
                     RRF_RT_REG_BINARY, nullptr, data, &size_bytes);
  return status == ERROR_SUCCESS && size_bytes >= 1 && (data[0] & 0x01) != 0;
}

LaunchAtLoginState QueryLaunchAtLogin() {
  LaunchAtLoginState state;
  std::wstring value;
  const LSTATUS status = ReadRunValue(&value);
  if (status == ERROR_FILE_NOT_FOUND) {
    state.status = "disabled";
    state.message = "Автозапуск выключен.";
    return state;
  }
  if (status != ERROR_SUCCESS) {
    state.status = "error";
    state.message = "Не удалось прочитать настройку автозапуска из реестра "
                    "Windows (код " +
                    std::to_string(status) + ").";
    return state;
  }
  state.registered = true;
  const std::wstring exe_path = GetExecutablePath();
  if (exe_path.empty() || !EqualsIgnoreCase(value, BuildRunCommand(exe_path))) {
    state.status = "error";
    state.message = "В автозапуске Windows указан другой путь к REBOOT. "
                    "Выключите и снова включите автозапуск.";
    return state;
  }
  if (IsTurnedOffInStartupApps()) {
    state.status = "requiresApproval";
    state.message = "Автозапуск REBOOT отключён в Windows. Включите его: "
                    "Параметры → Приложения → Автозагрузка.";
    return state;
  }
  state.status = "enabled";
  state.message = "REBOOT запускается при входе в Windows в фоне, значок — "
                  "в области уведомлений.";
  return state;
}

bool EnableLaunchAtLogin(std::string* error) {
  const std::wstring exe_path = GetExecutablePath();
  if (exe_path.empty()) {
    *error = "Не удалось определить путь к файлу REBOOT.";
    return false;
  }
  const std::wstring command = BuildRunCommand(exe_path);

  HKEY key = nullptr;
  LSTATUS status = ::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr,
                                     REG_OPTION_NON_VOLATILE, KEY_SET_VALUE,
                                     nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) {
    *error = "Не удалось открыть раздел автозапуска в реестре Windows (код " +
             std::to_string(status) + ").";
    return false;
  }
  const DWORD data_bytes =
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
  status = ::RegSetValueExW(key, kRunValueName, 0, REG_SZ,
                            reinterpret_cast<const BYTE*>(command.c_str()),
                            data_bytes);
  ::RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    *error = "Не удалось включить автозапуск: ошибка реестра Windows (код " +
             std::to_string(status) + ").";
    return false;
  }
  return true;
}

bool DisableLaunchAtLogin(std::string* error) {
  HKEY key = nullptr;
  LSTATUS status = ::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0,
                                   KEY_SET_VALUE, &key);
  if (status == ERROR_FILE_NOT_FOUND) {
    return true;  // No Run key at all: nothing to remove.
  }
  if (status != ERROR_SUCCESS) {
    *error = "Не удалось открыть раздел автозапуска в реестре Windows (код " +
             std::to_string(status) + ").";
    return false;
  }
  status = ::RegDeleteValueW(key, kRunValueName);
  ::RegCloseKey(key);
  if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) {
    *error = "Не удалось выключить автозапуск: ошибка реестра Windows (код " +
             std::to_string(status) + ").";
    return false;
  }
  return true;
}

}  // namespace

AppShell::AppShell(flutter::BinaryMessenger* messenger,
                   HWND window,
                   bool started_in_background,
                   UsageCollector* collector,
                   std::function<void()> on_window_shown)
    : window_(window),
      collector_(collector),
      on_window_shown_(std::move(on_window_shown)),
      started_in_background_(started_in_background),
      hidden_by_shell_(started_in_background),
      tooltip_(L"REBOOT") {
  // Explorer broadcasts this after it (re)starts; the icon must be re-added.
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  // Posted by a second instance started without --background (main.cpp).
  show_window_message_ = ::RegisterWindowMessageW(kShowWindowMessageName);

  tray_icon_ = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  owns_tray_icon_ = tray_icon_ != nullptr;
  if (tray_icon_ == nullptr) {
    // Shared icon: must not be passed to DestroyIcon.
    tray_icon_ =
        ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  }

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             MethodResultPtr result) {
        HandleMethodCall(call, std::move(result));
      });

  // v1.1: the icon is shown for the whole lifetime of the process.
  UpdateTrayIcon();
  if (started_in_background_ && !icon_added_) {
    // No notification area right now: never keep running invisibly. The
    // window is shown; TaskbarCreated adds the icon later.
    ShowMainWindow();
  }
}

AppShell::~AppShell() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  if (quit_timer_active_ && window_ != nullptr) {
    ::KillTimer(window_, kQuitTimerId);
    quit_timer_active_ = false;
  }
  RemoveTrayIcon();
  if (tray_icon_ != nullptr && owns_tray_icon_) {
    ::DestroyIcon(tray_icon_);
  }
  tray_icon_ = nullptr;
}

// ---------------------------------------------------------------------------
// Method channel

void AppShell::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    MethodResultPtr result) {
  const std::string& method = call.method_name();

  if (method == "getAppState") {
    result->Success(BuildState());
    return;
  }

  if (method == "setBackgroundMode") {
    bool enabled = false;
    if (!GetBoolArgument(call.arguments(), "enabled", &enabled)) {
      result->Error("bad_args", "Ожидается аргумент enabled: bool.");
      return;
    }
    // v1.1: accepted but ignored; background mode is always on on Windows.
    UpdateTrayIcon();
    result->Success(BuildState());
    return;
  }

  if (method == "setLaunchAtLogin") {
    bool enabled = false;
    if (!GetBoolArgument(call.arguments(), "enabled", &enabled)) {
      result->Error("bad_args", "Ожидается аргумент enabled: bool.");
      return;
    }
    std::string error;
    const bool ok =
        enabled ? EnableLaunchAtLogin(&error) : DisableLaunchAtLogin(&error);
    if (!ok) {
      result->Error("launch_at_login_failed", error);
      return;
    }
    result->Success(BuildState());
    return;
  }

  if (method == "updateStatus") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "Ожидается словарь со статусом.");
      return;
    }
    // "title" is for the macOS menu bar button and "progress" is not shown
    // on Windows; both are accepted and ignored here.
    status_lines_.clear();
    const auto lines_it = args->find(Str("lines"));
    if (lines_it != args->end()) {
      if (const auto* lines =
              std::get_if<flutter::EncodableList>(&lines_it->second)) {
        for (const flutter::EncodableValue& item : *lines) {
          if (status_lines_.size() >= kMaxStatusLines) {
            break;
          }
          if (const auto* text = std::get_if<std::string>(&item)) {
            std::wstring line =
                LimitLength(Utf16FromUtf8(*text), kMaxStatusLineChars);
            if (!line.empty()) {
              status_lines_.push_back(std::move(line));
            }
          }
        }
      }
    }
    const auto collecting_it = args->find(Str("collecting"));
    if (collecting_it != args->end()) {
      if (const bool* collecting = std::get_if<bool>(&collecting_it->second)) {
        collecting_ = *collecting;
      }
    }
    std::wstring tooltip = L"REBOOT";
    if (!status_lines_.empty()) {
      tooltip += L" — " + status_lines_.front();
    }
    tooltip_ = LimitLength(tooltip, kMaxTooltipChars);
    ApplyTooltip();
    result->Success();
    return;
  }

  if (method == "showWindow") {
    ShowMainWindow();
    result->Success();
    return;
  }

  if (method == "hideWindow") {
    HideMainWindow();  // No-op if there is no tray icon to come back from.
    result->Success();
    return;
  }

  if (method == "getFrontmostApp") {
    result->Success(GetFrontmostApp());
    return;
  }

  if (method == "limitApp") {
    std::string app_identifier;
    if (const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments())) {
      const auto it = args->find(Str("appIdentifier"));
      if (it != args->end()) {
        if (const auto* text = std::get_if<std::string>(&it->second)) {
          app_identifier = *text;
        }
      }
    }
    if (app_identifier.empty()) {
      result->Error("bad_args", "Ожидается аргумент appIdentifier: String.");
      return;
    }
    result->Success(LimitApp(app_identifier));
    return;
  }

  if (method == "quit") {
    // Reply first, then quit from a posted message so that the engine is not
    // torn down inside its own platform-message callback.
    result->Success();
    quitting_ = true;
    if (window_ == nullptr ||
        !::PostMessageW(window_, kQuitMessage, 0, 0)) {
      ::PostQuitMessage(0);
    }
    return;
  }

  result->NotImplemented();
}

flutter::EncodableValue AppShell::BuildState() const {
  const LaunchAtLoginState login = QueryLaunchAtLogin();
  const bool tray_available =
      icon_added_ ||
      (!icon_add_failed_ && ::FindWindowW(L"Shell_TrayWnd", nullptr) != nullptr);

  flutter::EncodableMap state;
  state[Str("backgroundMode")] = flutter::EncodableValue(background_mode_);
  state[Str("windowVisible")] = flutter::EncodableValue(IsWindowShown());
  state[Str("launchAtLogin")] = flutter::EncodableValue(login.registered);
  state[Str("launchAtLoginStatus")] = Str(login.status);
  state[Str("launchAtLoginMessage")] = Str(login.message);
  state[Str("startedInBackground")] =
      flutter::EncodableValue(started_in_background_);
  state[Str("trayAvailable")] = flutter::EncodableValue(tray_available);
  return flutter::EncodableValue(state);
}

// ---------------------------------------------------------------------------
// v1.1 app limits

flutter::EncodableValue AppShell::GetFrontmostApp() {
  UsageCollector::ForegroundApp app;
  if (collector_ == nullptr || !collector_->GetForegroundApp(&app)) {
    return flutter::EncodableValue();  // null
  }
  const DWORD self_pid = ::GetCurrentProcessId();
  if (app.window_pid == self_pid || app.app_pid == self_pid) {
    return flutter::EncodableValue();  // REBOOT itself is frontmost.
  }
  flutter::EncodableMap map;
  map[Str("appIdentifier")] = Str(app.identifier);
  map[Str("displayName")] = Str(app.display_name);
  return flutter::EncodableValue(map);
}

flutter::EncodableValue AppShell::LimitApp(const std::string& app_identifier) {
  bool applied = false;
  std::string message;

  UsageCollector::ForegroundApp app;
  const DWORD self_pid = ::GetCurrentProcessId();
  if (collector_ == nullptr || !collector_->GetForegroundApp(&app) ||
      app.window_pid == self_pid || app.app_pid == self_pid ||
      app.identifier != app_identifier) {
    // Soft limit: only the app that is in front right now is touched.
    message = "Приложение сейчас не на переднем плане, ничего не сделано.";
  } else {
    // Minimize the top-level owner (a focused dialog is owned by the main
    // window). For UWP the foreground window already is the frame window.
    HWND target = ::GetAncestor(app.window, GA_ROOTOWNER);
    if (target == nullptr) {
      target = app.window;
    }
    if (::IsHungAppWindow(target)) {
      // ShowWindow on a hung window of another thread could block the UI.
      message = "Окно «" + app.display_name +
                "» не отвечает, свернуть его не удалось.";
    } else {
      ::ShowWindow(target, SW_MINIMIZE);
      applied = ::IsIconic(target) != FALSE;
      message = applied
                    ? "«" + app.display_name + "» свёрнуто."
                    : "Windows не дала свернуть «" + app.display_name +
                          "» (например, оно запущено от имени "
                          "администратора).";
    }
    // Same as "showWindow". Processes are never terminated.
    ShowMainWindow();
  }

  flutter::EncodableMap map;
  map[Str("applied")] = flutter::EncodableValue(applied);
  map[Str("message")] = Str(message);
  return flutter::EncodableValue(map);
}

// ---------------------------------------------------------------------------
// Window visibility

bool AppShell::IsWindowShown() const {
  return window_ != nullptr && ::IsWindowVisible(window_) != FALSE;
}

void AppShell::ShowMainWindow() {
  if (window_ == nullptr) {
    return;
  }
  const bool was_visible = IsWindowShown();
  hidden_by_shell_ = false;
  ::ShowWindow(window_, SW_SHOW);
  if (::IsIconic(window_)) {
    ::ShowWindow(window_, SW_RESTORE);
  }
  ::SetForegroundWindow(window_);
  UpdateTrayIcon();
  if (on_window_shown_) {
    on_window_shown_();
  }
  if (!was_visible) {
    NotifyVisibility(true);
  }
}

bool AppShell::HideMainWindow() {
  if (window_ == nullptr) {
    return false;
  }
  // The icon must exist before hiding, so there is never a moment with
  // neither window nor icon. Probe it: Explorer may be gone (restarting)
  // without TaskbarCreated having arrived yet.
  if (icon_added_ && !ApplyTooltip()) {
    icon_added_ = false;
  }
  UpdateTrayIcon();
  if (!icon_added_) {
    return false;  // No notification area (Explorer not running).
  }
  const bool was_visible = IsWindowShown();
  hidden_by_shell_ = true;
  ::ShowWindow(window_, SW_HIDE);
  if (was_visible) {
    NotifyVisibility(false);
  }
  return true;
}

void AppShell::NotifyVisibility(bool visible) {
  if (!channel_) {
    return;
  }
  flutter::EncodableMap args;
  args[Str("visible")] = flutter::EncodableValue(visible);
  channel_->InvokeMethod("windowVisibilityChanged",
                         std::make_unique<flutter::EncodableValue>(args));
}

// ---------------------------------------------------------------------------
// Tray icon

void AppShell::UpdateTrayIcon() {
  const bool wanted = background_mode_ || hidden_by_shell_;
  if (wanted && !icon_added_) {
    AddTrayIcon();
  } else if (!wanted && icon_added_) {
    RemoveTrayIcon();
  }
}

bool AppShell::AddTrayIcon() {
  if (window_ == nullptr) {
    return false;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = static_cast<DWORD>(sizeof(data));
  data.hWnd = window_;
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = tray_icon_;
  wcsncpy_s(data.szTip, ARRAYSIZE(data.szTip), tooltip_.c_str(), _TRUNCATE);
  if (!::Shell_NotifyIconW(NIM_ADD, &data)) {
    icon_add_failed_ = true;
    return false;
  }
  icon_added_ = true;
  icon_add_failed_ = false;

  data.uVersion = NOTIFYICON_VERSION_4;
  icon_version4_ = ::Shell_NotifyIconW(NIM_SETVERSION, &data) != FALSE;
  return true;
}

void AppShell::RemoveTrayIcon() {
  if (!icon_added_ || window_ == nullptr) {
    icon_added_ = false;
    return;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = static_cast<DWORD>(sizeof(data));
  data.hWnd = window_;
  data.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  icon_added_ = false;
}

bool AppShell::ApplyTooltip() {
  if (!icon_added_ || window_ == nullptr) {
    return false;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = static_cast<DWORD>(sizeof(data));
  data.hWnd = window_;
  data.uID = kTrayIconId;
  data.uFlags = NIF_TIP | NIF_SHOWTIP;
  wcsncpy_s(data.szTip, ARRAYSIZE(data.szTip), tooltip_.c_str(), _TRUNCATE);
  return ::Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
}

void AppShell::HandleTrayCallback(WPARAM wparam, LPARAM lparam) {
  if (icon_version4_) {
    // NOTIFYICON_VERSION_4: LOWORD(lParam) is the event, wParam holds the
    // anchor point (GET_X_LPARAM / GET_Y_LPARAM).
    const UINT event = LOWORD(lparam);
    switch (event) {
      case WM_CONTEXTMENU:  // Right click or Shift+F10 / menu key.
      case NIN_SELECT:      // Left click.
      case NIN_KEYSELECT: {  // Enter / Space on the focused icon.
        const int x = static_cast<short>(LOWORD(wparam));
        const int y = static_cast<short>(HIWORD(wparam));
        ShowTrayMenu(x, y);
        break;
      }
      default:
        break;
    }
    return;
  }

  // Legacy callback (NIM_SETVERSION failed): lParam is the mouse message.
  const UINT event = static_cast<UINT>(lparam);
  if (event == WM_LBUTTONUP || event == WM_RBUTTONUP) {
    POINT cursor = {};
    ::GetCursorPos(&cursor);
    ShowTrayMenu(static_cast<int>(cursor.x), static_cast<int>(cursor.y));
  }
}

void AppShell::ShowTrayMenu(int x, int y) {
  if (window_ == nullptr) {
    return;
  }
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  // 1. Status lines (disabled items).
  if (status_lines_.empty()) {
    ::AppendMenuW(menu, MF_STRING | MF_GRAYED,
                  static_cast<UINT_PTR>(kCmdStatusBase), L"REBOOT");
  } else {
    for (size_t i = 0; i < status_lines_.size(); ++i) {
      ::AppendMenuW(menu, MF_STRING | MF_GRAYED,
                    static_cast<UINT_PTR>(kCmdStatusBase) + i,
                    EscapeMenuText(status_lines_[i]).c_str());
    }
  }
  // 2. separator, 3. open, 4. toggle collection, 5. separator, 6. quit.
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(kCmdOpen),
                L"Открыть REBOOT");
  ::AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(kCmdToggleCollection),
                collecting_ ? L"Остановить сбор" : L"Возобновить сбор");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(kCmdQuit),
                L"Завершить REBOOT");
  ::SetMenuDefaultItem(menu, static_cast<UINT>(kCmdOpen), FALSE);

  // Required so that the menu closes when the user clicks elsewhere.
  ::SetForegroundWindow(window_);
  UINT flags = TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY;
  if (::GetSystemMetrics(SM_MENUDROPALIGNMENT) != 0) {
    flags |= static_cast<UINT>(TPM_RIGHTALIGN);
  } else {
    flags |= static_cast<UINT>(TPM_LEFTALIGN);
  }
  menu_active_ = true;
  const BOOL command =
      ::TrackPopupMenu(menu, flags, x, y, 0, window_, nullptr);
  menu_active_ = false;
  // See "PRB: Menus for Notification Icons Do Not Work Correctly".
  ::PostMessageW(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  switch (command) {
    case kCmdOpen:
      ShowMainWindow();
      SendTrayAction("open");
      break;
    case kCmdToggleCollection:
      SendTrayAction("toggleCollection");
      break;
    case kCmdQuit:
      // Dart saves its data and calls "quit"; the timer is the safety net.
      SendTrayAction("quit");
      StartQuitSafetyNet();
      break;
    default:
      break;
  }
}

// ---------------------------------------------------------------------------
// Quit flow

void AppShell::SendTrayAction(const char* action) {
  if (!channel_) {
    return;
  }
  flutter::EncodableMap args;
  args[Str("action")] = Str(action);
  channel_->InvokeMethod("trayAction",
                         std::make_unique<flutter::EncodableValue>(args));
}

void AppShell::StartQuitSafetyNet() {
  if (quit_timer_active_ || window_ == nullptr) {
    return;
  }
  // If SetTimer fails (practically never), quitting relies on Dart's "quit".
  quit_timer_active_ =
      ::SetTimer(window_, kQuitTimerId, kQuitTimeoutMs, nullptr) != 0;
}

void AppShell::PerformQuit(HWND hwnd) {
  quitting_ = true;
  if (quit_timer_active_) {
    ::KillTimer(hwnd, kQuitTimerId);
    quit_timer_active_ = false;
  }
  RemoveTrayIcon();
  // DestroyWindow -> WM_DESTROY -> FlutterWindow::OnDestroy deletes this
  // AppShell, and Win32Window posts WM_QUIT (SetQuitOnClose(true) in main).
  // Nothing below may touch members.
  if (!::DestroyWindow(hwnd)) {
    ::PostQuitMessage(0);
  }
}

// ---------------------------------------------------------------------------
// Window messages

std::optional<LRESULT> AppShell::HandleWindowMessage(HWND hwnd,
                                                     UINT message,
                                                     WPARAM wparam,
                                                     LPARAM lparam) {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    // Explorer restarted (or the taskbar DPI changed): re-create the icon.
    if (icon_added_) {
      RemoveTrayIcon();
    }
    icon_add_failed_ = false;
    UpdateTrayIcon();
    return 0;
  }

  if (show_window_message_ != 0 && message == show_window_message_) {
    // Same as "showWindow": show + focus; windowVisibilityChanged is sent
    // when the window was hidden.
    ShowMainWindow();
    return 0;
  }

  switch (message) {
    case WM_CLOSE:
      // Before Flutter's HandleTopLevelWindowProc: the close button, Alt+F4
      // and "Close window" only hide the window to the tray; no exit request
      // reaches Dart. Passed on (normal quit) while quitting, while Windows
      // is ending the session, or when there is no tray icon to come back
      // from.
      if (background_mode_ && !quitting_ && !session_ending_ &&
          HideMainWindow()) {
        return 0;
      }
      break;

    case WM_QUERYENDSESSION:
      // Observed only: never blocks or cancels shutdown / logoff.
      session_ending_ = true;
      break;

    case WM_ENDSESSION:
      if (wparam == 0) {
        session_ending_ = false;  // Session end was cancelled.
      }
      break;

    case kTrayCallbackMessage:
      HandleTrayCallback(wparam, lparam);
      if (quit_after_menu_) {
        PerformQuit(hwnd);  // Deletes this.
      }
      return 0;

    case kQuitMessage:
      if (menu_active_) {
        // TrackPopupMenu's modal loop is on the stack; quit after it ends.
        quit_after_menu_ = true;
        ::EndMenu();
        return 0;
      }
      PerformQuit(hwnd);  // Deletes this.
      return 0;

    case WM_TIMER:
      if (wparam == kQuitTimerId) {
        ::KillTimer(hwnd, kQuitTimerId);
        quit_timer_active_ = false;
        if (menu_active_) {
          quit_after_menu_ = true;
          ::EndMenu();
          return 0;
        }
        PerformQuit(hwnd);  // Deletes this.
        return 0;
      }
      break;

    default:
      break;
  }
  return std::nullopt;
}
