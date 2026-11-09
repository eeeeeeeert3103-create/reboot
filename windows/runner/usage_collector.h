#ifndef RUNNER_USAGE_COLLECTOR_H_
#define RUNNER_USAGE_COLLECTOR_H_

// windows.h must come before any other Windows SDK header (wtsapi32.h is
// included only in the .cpp file, after windows.h).
#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <utility>

// Local usage collector for the "reboot/collector" method channel
// (collector contract v1).
//
// Collects only: the lower-cased executable file name and the FileDescription
// of the foreground process, idle periods (no input for >= 120 s), session
// lock/unlock and system suspend/resume. It never collects window titles, full
// paths, URLs, keystrokes, screenshots or app content, and never uses the
// network. Data is kept in memory until Dart drains it.
//
// Everything runs on the UI thread: a 1 s SetTimer on the top-level window
// delivers WM_TIMER through FlutterWindow::MessageHandler, which also forwards
// WM_WTSSESSION_CHANGE and WM_POWERBROADCAST to HandleWindowMessage.
class UsageCollector {
 public:
  UsageCollector(flutter::BinaryMessenger* messenger, HWND window);
  ~UsageCollector();

  UsageCollector(const UsageCollector&) = delete;
  UsageCollector& operator=(const UsageCollector&) = delete;

  // Returns a value when the message was fully handled by the collector (only
  // its own WM_TIMER). Session and power notifications are observed and
  // std::nullopt is returned so that normal processing continues.
  std::optional<LRESULT> HandleWindowMessage(HWND hwnd,
                                             UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam);

  // Current foreground app, resolved exactly like collected events
  // (lower-cased exe name, FileDescription, UWP frame -> hosted app). Used by
  // AppShell for getFrontmostApp / limitApp; works whether or not collection
  // is running. Returns false when there is no resolvable foreground window.
  struct ForegroundApp {
    HWND window = nullptr;    // GetForegroundWindow() (UWP: the frame).
    DWORD window_pid = 0;     // Owner of |window| (UWP: ApplicationFrameHost).
    DWORD app_pid = 0;        // Resolved app process (UWP: hosted app).
    std::string identifier;   // e.g. "chrome.exe".
    std::string display_name;
  };
  bool GetForegroundApp(ForegroundApp* out);

 private:
  enum class Lifecycle { kReady, kCollecting, kStopped, kFailed };

  struct Event {
    const char* type = "";
    int64_t timestamp_ms = 0;  // Milliseconds since 1601-01-01 UTC.
    std::string app_identifier;
    std::string display_name;
    bool has_duration = false;
    int64_t duration_seconds = 0;
  };

  struct AppInfo {
    std::string identifier;    // Lower-cased exe file name, UTF-8.
    std::string display_name;  // FileDescription or exe name without ".exe".
    DWORD pid = 0;
    uint64_t creation_time = 0;  // FILETIME of process creation, 0 if unknown.
  };

  struct Segment {
    bool open = false;
    std::string app_identifier;
    std::string display_name;
    int64_t start_ms = 0;
  };

  using MethodResultPtr =
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      MethodResultPtr result);

  // Method implementations.
  bool Start();
  void Stop();
  flutter::EncodableValue BuildStatus() const;
  flutter::EncodableValue DrainEvents();

  // Collection logic.
  void OnTick();
  void CheckIdle(int64_t now_ms);
  void PollForeground(int64_t now_ms);
  void OnSessionChange(WPARAM wparam);
  void OnPowerBroadcast(WPARAM wparam);
  void EnterUnavailable(int64_t now_ms);
  void LeaveUnavailable(int64_t now_ms);
  bool IsUnavailable() const { return locked_ || suspended_; }

  // Segment helpers. CloseSegment returns the timestamp it used.
  void OpenSegment(const std::string& app_identifier,
                   const std::string& display_name,
                   int64_t timestamp_ms);
  int64_t CloseSegment(int64_t timestamp_ms);

  // Event buffer helpers.
  void PushEvent(Event event);
  void PushSimpleEvent(const char* type, int64_t timestamp_ms);
  void NoteStateEvent(int64_t timestamp_ms);

  // Foreground process resolution.
  bool ResolveForegroundApp(AppInfo* out);
  bool ResolveWindowApp(HWND foreground, AppInfo* out);
  bool QueryProcess(DWORD pid, AppInfo* out);
  std::string LookupDisplayName(const std::wstring& image_path,
                                const std::wstring& exe_name);
  void NoteProcessSeen(const AppInfo& app, int64_t now_ms);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_ = nullptr;

  Lifecycle lifecycle_ = Lifecycle::kReady;
  bool timer_active_ = false;
  bool session_notifications_registered_ = false;

  bool idle_ = false;
  bool locked_ = false;
  bool suspended_ = false;

  Segment segment_;
  uint32_t tick_count_ = 0;
  int64_t last_tick_ms_ = 0;
  // Time of the last state event (start, unlock/resume, idleEnded). The
  // backdated idle start is never placed before it.
  int64_t state_floor_ms_ = 0;

  std::deque<Event> events_;

  // Processes seen as foreground in this collector run, keyed by
  // (pid, creation time) so that a reused pid counts as a new process.
  std::set<std::pair<DWORD, uint64_t>> seen_processes_;
  std::deque<std::pair<DWORD, uint64_t>> seen_order_;

  // Full image path -> display name. Paths stay in memory only.
  std::unordered_map<std::wstring, std::string> display_name_cache_;
};

#endif  // RUNNER_USAGE_COLLECTOR_H_
