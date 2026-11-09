import Cocoa
#if canImport(FlutterMacOS)
import FlutterMacOS
#endif

/// REBOOT usage collector (contract v1, channel `reboot/collector`).
///
/// Records only which application is frontmost, when apps are launched, idle periods
/// (no user input for >= 120 s) and lock / sleep periods. It never reads window titles,
/// URLs, document names, keystrokes, screenshots or any app content, and never uses
/// the network. All work happens on the main thread.
final class UsageCollector {
  enum Lifecycle: String {
    case ready
    case collecting
    case stopped
  }

  static let pollInterval: TimeInterval = 5
  static let idleThreshold: TimeInterval = 120
  static let bufferCap = 20_000

  private struct AppInfo: Equatable {
    let identifier: String?
    let displayName: String?
    let processIdentifier: pid_t

    init?(_ app: NSRunningApplication) {
      let bundleId = app.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
      let executable = app.executableURL?.lastPathComponent
      let identifier = bundleId ?? executable.flatMap { $0.isEmpty ? nil : $0 }
      let name = app.localizedName.flatMap { $0.isEmpty ? nil : $0 }
      if identifier == nil && name == nil { return nil }
      self.identifier = identifier
      self.displayName = name
      self.processIdentifier = app.processIdentifier
    }

    var fields: [String: Any] {
      var result: [String: Any] = [:]
      if let identifier = identifier { result["appIdentifier"] = identifier }
      if let displayName = displayName { result["displayName"] = displayName }
      return result
    }
  }

  private struct Segment {
    let app: AppInfo
    let start: Date
  }

  private struct Event {
    let date: Date
    let payload: [String: Any]
  }

  /// Reasons the session is considered locked. Locked while the set is non-empty.
  private enum LockReason: Hashable {
    case screenLocked
    case sessionInactive
    case systemSleep
    case screensAsleep
  }

  private(set) var lifecycle: Lifecycle = .ready
  private var events: [Event] = []
  private var segment: Segment?
  private var lockReasons: Set<LockReason> = []
  private var isIdle = false
  /// Earliest allowed `idleStarted` timestamp: the latest state event (start, lock/unlock,
  /// wake, idle transition), so idle never reaches back into a locked period.
  /// Drains and checkpoints do not move it: Dart trims already stored sessions.
  private var stateFloor = Date.distantPast
  private var timer: Timer?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var distributedObservers: [NSObjectProtocol] = []

  /// Injectable for tests: seconds since the last user input event.
  var secondsSinceLastInput: () -> TimeInterval = {
    // kCGAnyInputEventType (~0): any input event type. Public, documented CoreGraphics API;
    // it reports only the elapsed time, never the event content.
    CGEventSource.secondsSinceLastEventType(
      .combinedSessionState,
      eventType: CGEventType(rawValue: ~0)!
    )
  }

  /// Injectable for tests: current time.
  var now: () -> Date = { Date() }

  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  static func iso(_ date: Date) -> String {
    return formatter.string(from: date)
  }

  var isCollecting: Bool { lifecycle == .collecting }
  var isLocked: Bool { !lockReasons.isEmpty }

  deinit {
    removeObservers()
  }

  // MARK: - Public API

  func status() -> [String: Any] {
    let message: String
    switch lifecycle {
    case .ready: message = "Сбор ещё не запускался"
    case .collecting: message = "Сбор идёт: учитывается только активное приложение"
    case .stopped: message = "Сбор остановлен"
    }
    return [
      "platform": "macOS",
      "lifecycle": lifecycle.rawValue,
      "permissionGranted": true,
      "collecting": isCollecting,
      "message": message,
      "checkedAt": UsageCollector.iso(now()),
    ]
  }

  func start() {
    guard !isCollecting else { return }
    lifecycle = .collecting
    lockReasons = []
    isIdle = false
    segment = nil
    addObservers()
    let timer = Timer(timeInterval: UsageCollector.pollInterval, repeats: true) { [weak self] _ in
      self?.pollIdle()
    }
    timer.tolerance = 1
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    let startedAt = now()
    stateFloor = startedAt
    startForegroundIfPossible(at: startedAt)
  }

  func stop() {
    guard isCollecting else { return }
    endSegment(at: now())
    removeObservers()
    timer?.invalidate()
    timer = nil
    lockReasons = []
    isIdle = false
    lifecycle = .stopped
  }

  func drainEvents() -> [String: Any] {
    let capturedAt = now()
    if isCollecting, let open = segment {
      endSegment(at: capturedAt)
      beginSegment(open.app, at: capturedAt)
    }
    let drained = events.map { $0.payload }
    events.removeAll()
    return [
      "platform": "macOS",
      "capturedAt": UsageCollector.iso(capturedAt),
      "events": drained,
    ]
  }

  // MARK: - Observers

  private func addObservers() {
    let workspace = NSWorkspace.shared.notificationCenter
    let main = OperationQueue.main
    func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
      workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: main, using: handler))
    }
    observe(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      self?.handleActivation(app)
    }
    observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      self?.handleLaunch(app)
    }
    observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
      self?.addLockReason(.sessionInactive)
    }
    observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
      self?.removeLockReasons([.sessionInactive])
    }
    observe(NSWorkspace.willSleepNotification) { [weak self] _ in
      self?.addLockReason(.systemSleep)
    }
    observe(NSWorkspace.didWakeNotification) { [weak self] _ in
      self?.removeLockReasons([.systemSleep])
    }
    observe(NSWorkspace.screensDidSleepNotification) { [weak self] _ in
      self?.addLockReason(.screensAsleep)
    }
    observe(NSWorkspace.screensDidWakeNotification) { [weak self] _ in
      self?.removeLockReasons([.screensAsleep])
    }

    let distributed = DistributedNotificationCenter.default()
    distributedObservers.append(distributed.addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: main
    ) { [weak self] _ in
      self?.addLockReason(.screenLocked)
    })
    distributedObservers.append(distributed.addObserver(
      forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: main
    ) { [weak self] _ in
      // A successful unlock means the user is present: the machine and displays are awake.
      self?.removeLockReasons([.screenLocked, .screensAsleep, .systemSleep])
    })
  }

  private func removeObservers() {
    let workspace = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach { workspace.removeObserver($0) }
    workspaceObservers.removeAll()
    let distributed = DistributedNotificationCenter.default()
    distributedObservers.forEach { distributed.removeObserver($0) }
    distributedObservers.removeAll()
  }

  // MARK: - Handlers (internal for smoke tests)

  func handleActivation(_ runningApp: NSRunningApplication?) {
    guard isCollecting, !isLocked, !isIdle else { return }
    guard let runningApp = runningApp, let app = AppInfo(runningApp) else { return }
    if let open = segment, open.app == app { return }
    let date = now()
    endSegment(at: date)
    beginSegment(app, at: date)
  }

  func handleLaunch(_ runningApp: NSRunningApplication?) {
    guard isCollecting, let runningApp = runningApp,
          runningApp.activationPolicy == .regular,
          let app = AppInfo(runningApp) else { return }
    var payload = app.fields
    let date = now()
    payload["type"] = "appLaunched"
    payload["timestamp"] = UsageCollector.iso(date)
    append(Event(date: date, payload: payload))
  }

  func pollIdle() {
    guard isCollecting, !isLocked else { return }
    let idleSeconds = max(0, secondsSinceLastInput())
    let date = now()
    if !isIdle && idleSeconds >= UsageCollector.idleThreshold {
      // idleStarted = real last-input time (may precede the last drain/checkpoint),
      // bounded only by the last state event. foregroundEnded = max(segment start,
      // last input). Buffer order: foregroundEnded, then idleStarted, even if
      // idleStarted is earlier (Dart sorts accordingly).
      let lastInput = max(date.addingTimeInterval(-idleSeconds), stateFloor)
      let endIndex = endSegment(at: lastInput)
      isIdle = true
      stateFloor = max(stateFloor, lastInput)
      let idleEvent = Event(date: lastInput, payload: ["type": "idleStarted", "timestamp": UsageCollector.iso(lastInput)])
      if let endIndex = endIndex {
        events.insert(idleEvent, at: endIndex + 1)
        trimBuffer()
      } else {
        append(idleEvent)
      }
    } else if isIdle && idleSeconds < UsageCollector.idleThreshold {
      isIdle = false
      appendSimple("idleEnded", at: date)
      startForegroundIfPossible(at: date)
    }
  }

  private func addLockReason(_ reason: LockReason) {
    guard isCollecting else { return }
    let wasLocked = isLocked
    lockReasons.insert(reason)
    guard !wasLocked else { return }
    let date = now()
    endSegment(at: date)
    appendSimple("sessionLocked", at: date)
  }

  private func removeLockReasons(_ reasons: Set<LockReason>) {
    guard isCollecting, isLocked else { return }
    lockReasons.subtract(reasons)
    guard !isLocked else { return }
    let date = now()
    appendSimple("sessionUnlocked", at: date)
    if isIdle {
      // Input during unlock (e.g. typing the password) ends idle on the spot.
      pollIdle()
    } else if max(0, secondsSinceLastInput()) >= UsageCollector.idleThreshold {
      // Woke up without the user (e.g. scheduled wake): idle, no foreground segment.
      isIdle = true
      appendSimple("idleStarted", at: date)
    } else {
      startForegroundIfPossible(at: date)
    }
  }

  // Test hooks for lock handling.
  func simulateLock() { addLockReason(.screenLocked) }
  func simulateUnlock() { removeLockReasons([.screenLocked, .screensAsleep, .systemSleep]) }

  // MARK: - Segments and buffer

  private func startForegroundIfPossible(at date: Date) {
    guard isCollecting, !isLocked, !isIdle, segment == nil else { return }
    guard let front = NSWorkspace.shared.frontmostApplication, let app = AppInfo(front) else { return }
    beginSegment(app, at: date)
  }

  private func beginSegment(_ app: AppInfo, at date: Date) {
    segment = Segment(app: app, start: date)
    var payload = app.fields
    payload["type"] = "foregroundStarted"
    payload["timestamp"] = UsageCollector.iso(date)
    append(Event(date: date, payload: payload))
  }

  /// Returns the buffer index of the emitted `foregroundEnded`, if any.
  @discardableResult
  private func endSegment(at date: Date) -> Int? {
    guard let open = segment else { return nil }
    segment = nil
    let end = max(date, open.start)
    var payload = open.app.fields
    payload["type"] = "foregroundEnded"
    payload["timestamp"] = UsageCollector.iso(end)
    payload["durationSeconds"] = max(0, Int(end.timeIntervalSince(open.start).rounded()))
    return append(Event(date: end, payload: payload))
  }

  private func appendSimple(_ type: String, at date: Date) {
    stateFloor = max(stateFloor, date)
    _ = append(Event(date: date, payload: ["type": type, "timestamp": UsageCollector.iso(date)]))
  }

  /// Keeps the buffer in chronological order (a backdated event may precede an
  /// `appLaunched` recorded meanwhile) and caps it at `bufferCap`, dropping the oldest.
  /// Exception: `idleStarted` is placed right after its `foregroundEnded` (see pollIdle).
  @discardableResult
  private func append(_ event: Event) -> Int? {
    var index = events.count
    if let last = events.last, event.date < last.date {
      index = events.lastIndex(where: { $0.date <= event.date }).map { $0 + 1 } ?? 0
    }
    events.insert(event, at: index)
    let removed = trimBuffer()
    return index - removed >= 0 ? index - removed : nil
  }

  @discardableResult
  private func trimBuffer() -> Int {
    let overflow = events.count - UsageCollector.bufferCap
    guard overflow > 0 else { return 0 }
    events.removeFirst(overflow)
    return overflow
  }
}

#if canImport(FlutterMacOS)
/// Bridges `UsageCollector` to the Flutter `reboot/collector` method channel.
final class UsageCollectorChannel {
  private let channel: FlutterMethodChannel
  private let collector = UsageCollector()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "reboot/collector", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    collector.stop()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus", "requestPermission":
      result(collector.status())
    case "start":
      let args = call.arguments as? [String: Any]
      guard args?["userConsent"] as? Bool == true else {
        result(FlutterError(code: "consent_required", message: "Нужно согласие пользователя на сбор.", details: nil))
        return
      }
      collector.start()
      result(nil)
    case "stop":
      collector.stop()
      result(nil)
    case "drainEvents":
      result(collector.drainEvents())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
#endif
