#include "usage_collector.h"

// windows.h is included by usage_collector.h; wtsapi32.h must follow it.
#include <windows.h>
#include <wtsapi32.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdio>
#include <cwchar>
#include <cwctype>
#include <variant>
#include <vector>

// Source strings below contain Russian UTF-8 text; the runner is compiled
// with /utf-8 (see runner/CMakeLists.txt), so narrow literals are UTF-8.

namespace {

constexpr char kChannelName[] = "reboot/collector";

constexpr UINT_PTR kTimerId = 0x52424354;  // 'RBCT', unique on this HWND.
constexpr UINT kTickIntervalMs = 1000;     // Foreground poll interval.
constexpr uint32_t kIdleCheckEveryTicks = 5;  // Idle poll every 5 s.
constexpr DWORD kIdleThresholdMs = 120000;    // Idle after 120 s w/o input.
// If two ticks are further apart than this (system sleep without
// PBT_APMSUSPEND, e.g. Modern Standby, or a long UI-thread stall), the open
// segment is closed at the last tick so that the gap is not counted as use.
constexpr int64_t kTickGapMs = 15000;

constexpr size_t kMaxEvents = 20000;
constexpr size_t kMaxSeenProcesses = 4096;
constexpr size_t kMaxDisplayNameCache = 512;
constexpr size_t kMaxDisplayNameChars = 128;

constexpr char kFrameHostExe[] = "applicationframehost.exe";
constexpr wchar_t kCoreWindowClass[] = L"Windows.UI.Core.CoreWindow";

uint64_t FileTimeToU64(const FILETIME& ft) {
  ULARGE_INTEGER value;
  value.LowPart = ft.dwLowDateTime;
  value.HighPart = ft.dwHighDateTime;
  return value.QuadPart;
}

// Current UTC wall-clock time in milliseconds since 1601-01-01.
int64_t NowMs() {
  FILETIME ft;
  ::GetSystemTimeAsFileTime(&ft);
  return static_cast<int64_t>(FileTimeToU64(ft) / 10000ULL);
}

// UTC ISO-8601 with milliseconds, e.g. "2026-11-05T09:26:03.953Z".
std::string FormatIso8601(int64_t ms) {
  if (ms < 0) {
    ms = 0;
  }
  ULARGE_INTEGER value;
  value.QuadPart = static_cast<ULONGLONG>(ms) * 10000ULL;
  FILETIME ft;
  ft.dwLowDateTime = value.LowPart;
  ft.dwHighDateTime = value.HighPart;
  SYSTEMTIME st;
  if (!::FileTimeToSystemTime(&ft, &st)) {
    return "1970-01-01T00:00:00.000Z";
  }
  char buffer[40];
  std::snprintf(buffer, sizeof(buffer), "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
                static_cast<unsigned int>(st.wYear),
                static_cast<unsigned int>(st.wMonth),
                static_cast<unsigned int>(st.wDay),
                static_cast<unsigned int>(st.wHour),
                static_cast<unsigned int>(st.wMinute),
                static_cast<unsigned int>(st.wSecond),
                static_cast<unsigned int>(st.wMilliseconds));
  return std::string(buffer);
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int wide_length = static_cast<int>(wide.size());
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                           wide_length, nullptr, 0, nullptr,
                                           nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(length), '\0');
  const int written =
      ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), wide_length, &utf8[0],
                            length, nullptr, nullptr);
  if (written <= 0) {
    return std::string();
  }
  utf8.resize(static_cast<size_t>(written));
  return utf8;
}

std::wstring ToLowerWide(std::wstring text) {
  if (!text.empty()) {
    ::CharLowerBuffW(&text[0], static_cast<DWORD>(text.size()));
  }
  return text;
}

std::wstring TrimWide(const std::wstring& text) {
  size_t begin = 0;
  size_t end = text.size();
  while (begin < end && std::iswspace(text[begin])) {
    ++begin;
  }
  while (end > begin && std::iswspace(text[end - 1])) {
    --end;
  }
  return text.substr(begin, end - begin);
}

// File name part of a full image path ("C:\...\chrome.exe" -> "chrome.exe").
std::wstring FileNameFromPath(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return path;
  }
  return path.substr(separator + 1);
}

bool QueryImagePath(HANDLE process, std::wstring* out) {
  DWORD capacity = MAX_PATH;
  for (int attempt = 0; attempt < 4; ++attempt) {
    std::wstring buffer(static_cast<size_t>(capacity), L'\0');
    DWORD size = capacity;
    if (::QueryFullProcessImageNameW(process, 0, &buffer[0], &size)) {
      buffer.resize(static_cast<size_t>(size));
      *out = buffer;
      return !out->empty();
    }
    if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
      return false;
    }
    capacity *= 4;  // 260 -> 1040 -> 4160 -> 16640 characters.
  }
  return false;
}

// Reads FileDescription from the version resource of |path|.
std::wstring ReadFileDescription(const std::wstring& path) {
  DWORD ignored_handle = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(path.c_str(), &ignored_handle);
  if (size == 0) {
    return std::wstring();
  }
  std::vector<BYTE> data(static_cast<size_t>(size));
  if (!::GetFileVersionInfoW(path.c_str(), 0, size, data.data())) {
    return std::wstring();
  }

  struct LangAndCodePage {
    WORD language;
    WORD code_page;
  };
  std::vector<LangAndCodePage> candidates;
  LangAndCodePage* translations = nullptr;
  UINT translations_bytes = 0;
  if (::VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
                       reinterpret_cast<LPVOID*>(&translations),
                       &translations_bytes) &&
      translations != nullptr) {
    const size_t count = translations_bytes / sizeof(LangAndCodePage);
    for (size_t i = 0; i < count; ++i) {
      candidates.push_back(translations[i]);
    }
  }
  // Common fallbacks for files without a (correct) translation table.
  candidates.push_back({0x0409, 0x04B0});
  candidates.push_back({0x0409, 0x04E4});
  candidates.push_back({0x0409, 0x0000});

  for (const LangAndCodePage& candidate : candidates) {
    wchar_t sub_block[64];
    std::swprintf(sub_block, sizeof(sub_block) / sizeof(sub_block[0]),
                  L"\\StringFileInfo\\%04x%04x\\FileDescription",
                  static_cast<unsigned int>(candidate.language),
                  static_cast<unsigned int>(candidate.code_page));
    LPWSTR value = nullptr;
    UINT value_chars = 0;
    if (::VerQueryValueW(data.data(), sub_block,
                         reinterpret_cast<LPVOID*>(&value), &value_chars) &&
        value != nullptr && value_chars > 0) {
      std::wstring description =
          TrimWide(std::wstring(value, ::wcsnlen(value, value_chars)));
      if (!description.empty()) {
        if (description.size() > kMaxDisplayNameChars) {
          description.resize(kMaxDisplayNameChars);
        }
        return description;
      }
    }
  }
  return std::wstring();
}

// Is the current session locked? Uses WTSSessionInfoEx (documented; the
// SessionFlags values are known to be inverted only on Windows 7 / Server
// 2008 R2, which Flutter does not support). Returns false when unknown.
bool IsCurrentSessionLocked() {
  LPWSTR buffer = nullptr;
  DWORD bytes = 0;
  if (!::WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,
                                     WTS_CURRENT_SESSION, WTSSessionInfoEx,
                                     &buffer, &bytes) ||
      buffer == nullptr) {
    return false;
  }
  bool locked = false;
  if (bytes >= sizeof(WTSINFOEXW)) {
    const WTSINFOEXW* info = reinterpret_cast<const WTSINFOEXW*>(buffer);
    if (info->Level == 1) {
      locked = info->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK;
    }
  }
  ::WTSFreeMemory(buffer);
  return locked;
}

struct CoreWindowSearch {
  DWORD host_pid = 0;
  DWORD app_pid = 0;
};

// UWP apps are hosted in an ApplicationFrameWindow owned by
// ApplicationFrameHost.exe; the app's own process owns a child window of class
// "Windows.UI.Core.CoreWindow". Only the class name is read, never the title.
BOOL CALLBACK FindCoreWindowProc(HWND child, LPARAM lparam) {
  CoreWindowSearch* search = reinterpret_cast<CoreWindowSearch*>(lparam);
  wchar_t class_name[64] = {};
  const int length = ::GetClassNameW(
      child, class_name, static_cast<int>(sizeof(class_name) / sizeof(wchar_t)));
  if (length > 0 && std::wcscmp(class_name, kCoreWindowClass) == 0) {
    DWORD pid = 0;
    ::GetWindowThreadProcessId(child, &pid);
    if (pid != 0 && pid != search->host_pid) {
      search->app_pid = pid;
      return FALSE;  // Stop enumeration.
    }
  }
  return TRUE;
}

flutter::EncodableValue Str(const std::string& value) {
  return flutter::EncodableValue(value);
}

}  // namespace

UsageCollector::UsageCollector(flutter::BinaryMessenger* messenger,
                               HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             MethodResultPtr result) {
        HandleMethodCall(call, std::move(result));
      });
}

UsageCollector::~UsageCollector() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  if (timer_active_) {
    ::KillTimer(window_, kTimerId);
    timer_active_ = false;
  }
  if (session_notifications_registered_) {
    ::WTSUnRegisterSessionNotification(window_);
    session_notifications_registered_ = false;
  }
}

// ---------------------------------------------------------------------------
// Method channel

void UsageCollector::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    MethodResultPtr result) {
  const std::string& method = call.method_name();

  if (method == "getStatus" || method == "requestPermission") {
    // No OS permission is needed on Windows for this data.
    result->Success(BuildStatus());
    return;
  }

  if (method == "start") {
    bool consent = false;
    if (const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments())) {
      const auto it = args->find(Str("userConsent"));
      if (it != args->end()) {
        if (const bool* value = std::get_if<bool>(&it->second)) {
          consent = *value;
        }
      }
    }
    if (!consent) {
      result->Error("consent_required",
                    "Сбор активности начнётся только после вашего согласия.");
      return;
    }
    if (Start()) {
      result->Success();
    } else {
      result->Error("start_failed",
                    "Не удалось запустить сбор: системный таймер Windows "
                    "недоступен.");
    }
    return;
  }

  if (method == "stop") {
    Stop();
    result->Success();
    return;
  }

  if (method == "drainEvents") {
    result->Success(DrainEvents());
    return;
  }

  result->NotImplemented();
}

bool UsageCollector::Start() {
  if (lifecycle_ == Lifecycle::kCollecting) {
    return true;  // Idempotent.
  }
  if (window_ == nullptr ||
      ::SetTimer(window_, kTimerId, kTickIntervalMs, nullptr) == 0) {
    lifecycle_ = Lifecycle::kFailed;
    return false;
  }
  timer_active_ = true;

  // Lock/unlock notifications. Not fatal if unavailable; the status message
  // says so.
  session_notifications_registered_ =
      ::WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION) !=
      FALSE;

  idle_ = false;
  locked_ = false;
  suspended_ = false;
  segment_ = Segment();
  tick_count_ = 0;
  seen_processes_.clear();
  seen_order_.clear();

  const int64_t now = NowMs();
  last_tick_ms_ = now;
  NoteStateEvent(now);
  lifecycle_ = Lifecycle::kCollecting;

  OnTick();  // Open the first segment right away.
  return true;
}

void UsageCollector::Stop() {
  if (lifecycle_ != Lifecycle::kCollecting) {
    return;  // Idempotent.
  }
  CloseSegment(NowMs());
  if (timer_active_) {
    ::KillTimer(window_, kTimerId);
    timer_active_ = false;
  }
  if (session_notifications_registered_) {
    ::WTSUnRegisterSessionNotification(window_);
    session_notifications_registered_ = false;
  }
  idle_ = false;
  locked_ = false;
  suspended_ = false;
  lifecycle_ = Lifecycle::kStopped;
}

flutter::EncodableValue UsageCollector::BuildStatus() const {
  std::string lifecycle;
  std::string message;
  switch (lifecycle_) {
    case Lifecycle::kReady:
      lifecycle = "ready";
      message =
          "Готово к запуску. REBOOT будет учитывать активное приложение, "
          "бездействие и блокировку экрана, пока он открыт. Данные остаются "
          "на этом компьютере.";
      break;
    case Lifecycle::kCollecting:
      lifecycle = "collecting";
      message = session_notifications_registered_
                    ? "Идёт сбор: активное приложение, бездействие и "
                      "блокировка экрана. Учёт ведётся только пока REBOOT "
                      "запущен."
                    : "Идёт сбор: активное приложение и бездействие. "
                      "Блокировку экрана Windows отследить не удалось. Учёт "
                      "ведётся только пока REBOOT запущен.";
      break;
    case Lifecycle::kStopped:
      lifecycle = "stopped";
      message = "Сбор остановлен. Новые данные не записываются.";
      break;
    case Lifecycle::kFailed:
      lifecycle = "failed";
      message =
          "Не удалось запустить сбор: системный таймер Windows недоступен.";
      break;
  }

  flutter::EncodableMap status;
  status[Str("platform")] = Str("windows");
  status[Str("lifecycle")] = Str(lifecycle);
  status[Str("permissionGranted")] = flutter::EncodableValue(true);
  status[Str("collecting")] =
      flutter::EncodableValue(lifecycle_ == Lifecycle::kCollecting);
  status[Str("message")] = Str(message);
  status[Str("checkedAt")] = Str(FormatIso8601(NowMs()));
  return flutter::EncodableValue(status);
}

flutter::EncodableValue UsageCollector::DrainEvents() {
  const int64_t now = NowMs();

  // Checkpoint: close and immediately reopen the open segment so that at most
  // one poll interval of data is lost on a crash.
  if (lifecycle_ == Lifecycle::kCollecting && segment_.open) {
    const std::string app_identifier = segment_.app_identifier;
    const std::string display_name = segment_.display_name;
    const int64_t checkpoint_ms = CloseSegment(now);
    OpenSegment(app_identifier, display_name, checkpoint_ms);
  }

  int64_t captured_ms = now;
  for (const Event& event : events_) {
    captured_ms = std::max(captured_ms, event.timestamp_ms);
  }

  flutter::EncodableList list;
  list.reserve(events_.size());
  for (const Event& event : events_) {
    flutter::EncodableMap map;
    map[Str("type")] = Str(event.type);
    map[Str("timestamp")] = Str(FormatIso8601(event.timestamp_ms));
    if (!event.app_identifier.empty()) {
      map[Str("appIdentifier")] = Str(event.app_identifier);
    }
    if (!event.display_name.empty()) {
      map[Str("displayName")] = Str(event.display_name);
    }
    if (event.has_duration) {
      map[Str("durationSeconds")] =
          flutter::EncodableValue(event.duration_seconds);
    }
    list.push_back(flutter::EncodableValue(map));
  }
  events_.clear();

  flutter::EncodableMap snapshot;
  snapshot[Str("platform")] = Str("windows");
  snapshot[Str("capturedAt")] = Str(FormatIso8601(captured_ms));
  snapshot[Str("events")] = flutter::EncodableValue(list);
  return flutter::EncodableValue(snapshot);
}

// ---------------------------------------------------------------------------
// Window messages

std::optional<LRESULT> UsageCollector::HandleWindowMessage(HWND hwnd,
                                                           UINT message,
                                                           WPARAM wparam,
                                                           LPARAM lparam) {
  switch (message) {
    case WM_TIMER:
      if (wparam == kTimerId) {
        if (lifecycle_ == Lifecycle::kCollecting) {
          OnTick();
        }
        return 0;
      }
      break;
    case WM_WTSSESSION_CHANGE:
      if (lifecycle_ == Lifecycle::kCollecting) {
        OnSessionChange(wparam);
      }
      break;
    case WM_POWERBROADCAST:
      if (lifecycle_ == Lifecycle::kCollecting) {
        OnPowerBroadcast(wparam);
      }
      break;
    default:
      break;
  }
  return std::nullopt;
}

void UsageCollector::OnSessionChange(WPARAM wparam) {
  const int64_t now = NowMs();
  switch (wparam) {
    case WTS_SESSION_LOCK:
    case WTS_CONSOLE_DISCONNECT:
    case WTS_REMOTE_DISCONNECT:
      // A disconnected session (e.g. fast user switching) is not in use.
      if (!locked_) {
        const bool was_available = !IsUnavailable();
        locked_ = true;
        if (was_available) {
          EnterUnavailable(now);
        }
      }
      break;
    case WTS_SESSION_UNLOCK:
      if (locked_) {
        locked_ = false;
        if (!IsUnavailable()) {
          LeaveUnavailable(now);
        }
      }
      break;
    case WTS_CONSOLE_CONNECT:
    case WTS_REMOTE_CONNECT:
      // Reconnecting does not by itself mean the user is back: the lock
      // screen may still be shown. Treat it as unlock only if the session is
      // reported as unlocked.
      if (locked_ && !IsCurrentSessionLocked()) {
        locked_ = false;
        if (!IsUnavailable()) {
          LeaveUnavailable(now);
        }
      }
      break;
    default:
      break;
  }
}

void UsageCollector::OnPowerBroadcast(WPARAM wparam) {
  const int64_t now = NowMs();
  switch (wparam) {
    case PBT_APMSUSPEND:
      if (!suspended_) {
        const bool was_available = !IsUnavailable();
        suspended_ = true;
        if (was_available) {
          EnterUnavailable(now);  // Sleep is reported as sessionLocked.
        }
      }
      break;
    case PBT_APMRESUMEAUTOMATIC:
    case PBT_APMRESUMESUSPEND:
      // Windows sends RESUMEAUTOMATIC on every wake and RESUMESUSPEND as well
      // when the wake was user-initiated; the flag prevents a double unlock.
      if (suspended_) {
        suspended_ = false;
        // The lock notification may not have arrived yet when the system
        // locks on sleep; do not report "unlocked" while the lock screen is
        // shown.
        if (!locked_ && IsCurrentSessionLocked()) {
          locked_ = true;
        }
        if (!IsUnavailable()) {
          LeaveUnavailable(now);
        }
      }
      break;
    default:
      break;
  }
}

void UsageCollector::EnterUnavailable(int64_t now_ms) {
  const int64_t timestamp = CloseSegment(now_ms);
  PushSimpleEvent("sessionLocked", timestamp);
}

void UsageCollector::LeaveUnavailable(int64_t now_ms) {
  PushSimpleEvent("sessionUnlocked", now_ms);
  NoteStateEvent(now_ms);
  last_tick_ms_ = now_ms;
  if (idle_) {
    // Unlocking needs input, so this normally ends the idle period at once.
    CheckIdle(now_ms);
  }
  if (!idle_) {
    PollForeground(now_ms);
  }
}

// ---------------------------------------------------------------------------
// Polling

void UsageCollector::OnTick() {
  const int64_t now = NowMs();

  if (segment_.open && last_tick_ms_ != 0 && now - last_tick_ms_ > kTickGapMs) {
    CloseSegment(last_tick_ms_);
  }
  last_tick_ms_ = now;

  if (IsUnavailable()) {
    return;  // Locked or asleep: nothing is open, nothing is polled.
  }

  if (tick_count_ % kIdleCheckEveryTicks == 0) {
    CheckIdle(now);
  }
  ++tick_count_;

  if (!idle_) {
    PollForeground(now);
  }
}

void UsageCollector::CheckIdle(int64_t now_ms) {
  LASTINPUTINFO input_info;
  input_info.cbSize = sizeof(LASTINPUTINFO);
  input_info.dwTime = 0;
  if (!::GetLastInputInfo(&input_info)) {
    return;
  }
  // DWORD subtraction is correct across the 49.7-day GetTickCount wrap.
  DWORD idle_ms = ::GetTickCount() - input_info.dwTime;
  if (idle_ms > 0x7FFFFFFFUL) {
    idle_ms = 0;  // dwTime slightly ahead of our GetTickCount read.
  }

  if (!idle_ && idle_ms >= kIdleThresholdMs) {
    // Real moment of the last input, limited only by the last state event.
    int64_t last_input_ms = now_ms - static_cast<int64_t>(idle_ms);
    last_input_ms = std::max(last_input_ms, state_floor_ms_);
    idle_ = true;
    if (segment_.open) {
      // foregroundEnded = max(segment start, last input); may be 0 seconds.
      CloseSegment(std::max(segment_.start_ms, last_input_ms));
    }
    PushSimpleEvent("idleStarted", last_input_ms);
  } else if (idle_ && idle_ms < kIdleThresholdMs) {
    idle_ = false;
    PushSimpleEvent("idleEnded", now_ms);
    NoteStateEvent(now_ms);
    // The caller polls the foreground app next and opens the new segment.
  }
}

void UsageCollector::PollForeground(int64_t now_ms) {
  AppInfo app;
  if (!ResolveForegroundApp(&app)) {
    // No foreground window or the process could not be queried: do not
    // attribute this time to any app.
    CloseSegment(now_ms);
    return;
  }

  if (segment_.open && segment_.app_identifier != app.identifier) {
    CloseSegment(now_ms);
  }
  NoteProcessSeen(app, now_ms);
  if (!segment_.open) {
    OpenSegment(app.identifier, app.display_name, now_ms);
  }
}

// ---------------------------------------------------------------------------
// Segments and events

void UsageCollector::OpenSegment(const std::string& app_identifier,
                                 const std::string& display_name,
                                 int64_t timestamp_ms) {
  if (segment_.open || app_identifier.empty()) {
    return;
  }
  segment_.open = true;
  segment_.app_identifier = app_identifier;
  segment_.display_name = display_name;
  segment_.start_ms = timestamp_ms;

  Event event;
  event.type = "foregroundStarted";
  event.timestamp_ms = timestamp_ms;
  event.app_identifier = app_identifier;
  event.display_name = display_name;
  PushEvent(std::move(event));
}

int64_t UsageCollector::CloseSegment(int64_t timestamp_ms) {
  if (!segment_.open) {
    return timestamp_ms;
  }
  // Never end a segment before it started (e.g. wall clock moved back).
  const int64_t end_ms = std::max(timestamp_ms, segment_.start_ms);
  const int64_t duration_ms = end_ms - segment_.start_ms;

  Event event;
  event.type = "foregroundEnded";
  event.timestamp_ms = end_ms;
  event.app_identifier = segment_.app_identifier;
  event.display_name = segment_.display_name;
  event.has_duration = true;
  event.duration_seconds = (duration_ms + 500) / 1000;  // Rounded, >= 0.
  PushEvent(std::move(event));

  segment_ = Segment();
  return end_ms;
}

void UsageCollector::PushEvent(Event event) {
  // Keep the buffer chronological. Almost always this appends; a backdated
  // idle start (or a wall-clock step back) is inserted after all events with
  // a timestamp <= its own, preserving emission order for equal timestamps.
  auto position = events_.end();
  while (position != events_.begin()) {
    auto previous = position;
    --previous;
    if (previous->timestamp_ms <= event.timestamp_ms) {
      break;
    }
    position = previous;
  }
  events_.insert(position, std::move(event));
  while (events_.size() > kMaxEvents) {
    events_.pop_front();  // Overflow: drop the oldest.
  }
}

void UsageCollector::PushSimpleEvent(const char* type, int64_t timestamp_ms) {
  Event event;
  event.type = type;
  event.timestamp_ms = timestamp_ms;
  PushEvent(std::move(event));
}

void UsageCollector::NoteStateEvent(int64_t timestamp_ms) {
  state_floor_ms_ = std::max(state_floor_ms_, timestamp_ms);
}

// ---------------------------------------------------------------------------
// Foreground process resolution

bool UsageCollector::ResolveForegroundApp(AppInfo* out) {
  return ResolveWindowApp(::GetForegroundWindow(), out);
}

bool UsageCollector::GetForegroundApp(ForegroundApp* out) {
  HWND foreground = ::GetForegroundWindow();
  AppInfo app;
  if (!ResolveWindowApp(foreground, &app)) {
    return false;
  }
  DWORD window_pid = 0;
  ::GetWindowThreadProcessId(foreground, &window_pid);
  out->window = foreground;
  out->window_pid = window_pid;
  out->app_pid = app.pid;
  out->identifier = app.identifier;
  out->display_name = app.display_name;
  return true;
}

bool UsageCollector::ResolveWindowApp(HWND foreground, AppInfo* out) {
  if (foreground == nullptr) {
    return false;
  }
  DWORD pid = 0;
  ::GetWindowThreadProcessId(foreground, &pid);
  if (pid == 0) {
    return false;
  }
  AppInfo app;
  if (!QueryProcess(pid, &app)) {
    return false;
  }

  // UWP: replace ApplicationFrameHost.exe with the process that owns the
  // hosted CoreWindow, when it is attached to the frame.
  if (app.identifier == kFrameHostExe) {
    CoreWindowSearch search;
    search.host_pid = pid;
    ::EnumChildWindows(foreground, FindCoreWindowProc,
                       reinterpret_cast<LPARAM>(&search));
    if (search.app_pid != 0) {
      AppInfo hosted;
      if (QueryProcess(search.app_pid, &hosted)) {
        app = hosted;
      }
    }
  }

  *out = app;
  return true;
}

bool UsageCollector::QueryProcess(DWORD pid, AppInfo* out) {
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return false;
  }
  std::wstring image_path;
  const bool have_path = QueryImagePath(process, &image_path);
  FILETIME creation = {};
  FILETIME exit_time = {};
  FILETIME kernel_time = {};
  FILETIME user_time = {};
  uint64_t created = 0;
  if (::GetProcessTimes(process, &creation, &exit_time, &kernel_time,
                        &user_time)) {
    created = FileTimeToU64(creation);
  }
  ::CloseHandle(process);
  if (!have_path) {
    return false;
  }

  // Only the file name leaves this function; the full path (which contains
  // the user name) is used locally to read version info and is never sent.
  const std::wstring exe_name = FileNameFromPath(image_path);
  if (exe_name.empty()) {
    return false;
  }
  const std::string identifier = WideToUtf8(ToLowerWide(exe_name));
  if (identifier.empty()) {
    return false;
  }

  out->identifier = identifier;
  out->display_name = LookupDisplayName(image_path, exe_name);
  out->pid = pid;
  out->creation_time = created;
  return true;
}

std::string UsageCollector::LookupDisplayName(const std::wstring& image_path,
                                              const std::wstring& exe_name) {
  const auto cached = display_name_cache_.find(image_path);
  if (cached != display_name_cache_.end()) {
    return cached->second;
  }

  std::string display_name = WideToUtf8(ReadFileDescription(image_path));
  if (display_name.empty()) {
    std::wstring stem = exe_name;
    const std::wstring lower = ToLowerWide(exe_name);
    if (lower.size() > 4 && lower.compare(lower.size() - 4, 4, L".exe") == 0) {
      stem = exe_name.substr(0, exe_name.size() - 4);
    }
    display_name = WideToUtf8(stem);
  }
  if (display_name.empty()) {
    display_name = WideToUtf8(ToLowerWide(exe_name));
  }

  if (display_name_cache_.size() >= kMaxDisplayNameCache) {
    display_name_cache_.clear();
  }
  display_name_cache_[image_path] = display_name;
  return display_name;
}

void UsageCollector::NoteProcessSeen(const AppInfo& app, int64_t now_ms) {
  const std::pair<DWORD, uint64_t> key(app.pid, app.creation_time);
  if (!seen_processes_.insert(key).second) {
    return;
  }
  seen_order_.push_back(key);
  while (seen_order_.size() > kMaxSeenProcesses) {
    seen_processes_.erase(seen_order_.front());
    seen_order_.pop_front();
  }

  Event event;
  event.type = "appLaunched";
  event.timestamp_ms = now_ms;
  event.app_identifier = app.identifier;
  event.display_name = app.display_name;
  PushEvent(std::move(event));
}
