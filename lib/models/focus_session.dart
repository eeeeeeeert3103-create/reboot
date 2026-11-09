import 'usage_history.dart';
import 'usage_report.dart';

/// How a focus session ended.
enum FocusStatus {
  /// The planned time ran out.
  completed,

  /// The user finished the session before the planned time.
  stopped,
}

DateTime? _parseTime(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// One finished focus session. Times are stored in UTC.
///
/// REBOOT does not block anything during a session: it is a self-control
/// timer, and the app statistics are computed afterwards from local history.
class FocusSession {
  FocusSession({
    required this.id,
    required this.plannedSeconds,
    required DateTime startedAt,
    required DateTime endedAt,
    required this.pausedSeconds,
    required this.status,
    List<String> workAppIds = const [],
  }) : startedAt = startedAt.toUtc(),
       endedAt = endedAt.toUtc(),
       workAppIds = List.unmodifiable(workAppIds) {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    if (plannedSeconds <= 0) {
      throw ArgumentError.value(plannedSeconds, 'plannedSeconds');
    }
    if (pausedSeconds < 0) {
      throw ArgumentError.value(pausedSeconds, 'pausedSeconds');
    }
    if (this.endedAt.isBefore(this.startedAt)) {
      throw ArgumentError('Session must not end before it starts.');
    }
  }

  factory FocusSession.fromMap(Map<Object?, Object?> map) {
    final id = map['id'], planned = map['plannedSeconds'];
    final paused = map['pausedSeconds'];
    final start = _parseTime(map['startedAt']);
    final end = _parseTime(map['endedAt']);
    final status = FocusStatus.values.where((s) => s.name == map['status']);
    final apps = map['workApps'];
    if (id is! String ||
        planned is! int ||
        paused is! int ||
        start == null ||
        end == null ||
        status.isEmpty ||
        (apps != null && apps is! List)) {
      throw const FormatException('Invalid focus session.');
    }
    try {
      return FocusSession(
        id: id,
        plannedSeconds: planned,
        startedAt: start,
        endedAt: end,
        pausedSeconds: paused,
        status: status.single,
        workAppIds: [
          for (final app in (apps as List?) ?? const [])
            if (app is String) app,
        ],
      );
    } on ArgumentError {
      throw const FormatException('Invalid focus session values.');
    }
  }

  final String id;
  final int plannedSeconds;
  final DateTime startedAt;
  final DateTime endedAt;
  final int pausedSeconds;
  final FocusStatus status;

  /// Apps the user marked as "work" for this session.
  final List<String> workAppIds;

  /// Wall-clock time between start and end, pauses included.
  int get spanSeconds => endedAt.difference(startedAt).inSeconds;

  /// Time actually spent in focus: the span minus pauses.
  int get focusedSeconds {
    final value = spanSeconds - pausedSeconds;
    return value < 0 ? 0 : value;
  }

  Map<String, Object> toMap() => {
    'id': id,
    'plannedSeconds': plannedSeconds,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'pausedSeconds': pausedSeconds,
    'status': status.name,
    'workApps': workAppIds,
  };
}

enum FocusTimerState { idle, running, paused, finished }

/// Focus timer driven by wall-clock time, not by counting ticks.
///
/// `remaining = planned − (now − start − paused)`, so the value stays right
/// when the window is minimised, the app is throttled or the computer sleeps.
/// A UI only needs to repaint from time to time and read [remainingSeconds].
class FocusTimer {
  FocusTimer({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  FocusTimerState _state = FocusTimerState.idle;
  DateTime? _startedAt;
  DateTime? _pauseStartedAt;
  Duration _paused = Duration.zero;
  int _plannedSeconds = 0;
  List<String> _workAppIds = const [];
  FocusSession? _result;

  static const minMinutes = 5;
  static const maxMinutes = 240;

  FocusTimerState get state {
    _checkCompletion();
    return _state;
  }

  bool get isActive =>
      state == FocusTimerState.running || state == FocusTimerState.paused;
  int get plannedSeconds => _plannedSeconds;
  DateTime? get startedAt => _startedAt;

  /// The finished session, set once the timer completes or is finished.
  FocusSession? get result {
    _checkCompletion();
    return _result;
  }

  int get pausedSeconds => _pausedAt(_clock().toUtc()).inSeconds;

  int get elapsedSeconds {
    _checkCompletion();
    if (_state == FocusTimerState.finished) {
      return _result?.focusedSeconds ?? 0;
    }
    return _elapsedAt(_clock().toUtc()).inSeconds.clamp(0, _plannedSeconds);
  }

  int get remainingSeconds => _plannedSeconds - elapsedSeconds;

  double get progress =>
      _plannedSeconds == 0 ? 0 : elapsedSeconds / _plannedSeconds;

  /// Starts a new session; any previous result is discarded.
  void start(int plannedSeconds, {Iterable<String> workAppIds = const []}) {
    if (plannedSeconds <= 0) {
      throw ArgumentError.value(plannedSeconds, 'plannedSeconds');
    }
    if (isActive) throw StateError('A focus session is already running.');
    _plannedSeconds = plannedSeconds;
    _startedAt = _clock().toUtc();
    _pauseStartedAt = null;
    _paused = Duration.zero;
    _workAppIds = List.unmodifiable(workAppIds);
    _result = null;
    _state = FocusTimerState.running;
  }

  void pause() {
    if (state != FocusTimerState.running) return;
    _pauseStartedAt = _clock().toUtc();
    _state = FocusTimerState.paused;
  }

  void resume() {
    if (state != FocusTimerState.paused) return;
    _paused = _pausedAt(_clock().toUtc());
    _pauseStartedAt = null;
    _state = FocusTimerState.running;
  }

  /// Finishes early (status [FocusStatus.stopped]). If the planned time has
  /// already run out, the session is reported as completed instead.
  FocusSession? finish() {
    if (!isActive) return _result;
    final now = _clock().toUtc();
    final paused = _pausedAt(now);
    _end(now, paused, FocusStatus.stopped);
    return _result;
  }

  /// Clears a finished session so a new one can be configured.
  void reset() {
    if (isActive) return;
    _state = FocusTimerState.idle;
    _result = null;
    _startedAt = null;
    _plannedSeconds = 0;
  }

  /// Completes the session once its planned time is used up. The end time is
  /// the exact moment the time ran out, even if the app noticed it later.
  void _checkCompletion() {
    if (_state != FocusTimerState.running) return;
    final now = _clock().toUtc();
    if (_elapsedAt(now).inSeconds < _plannedSeconds) return;
    final end = _startedAt!.add(Duration(seconds: _plannedSeconds) + _paused);
    _end(end, _paused, FocusStatus.completed);
  }

  void _end(DateTime end, Duration paused, FocusStatus status) {
    final start = _startedAt!;
    if (end.isBefore(start)) end = start;
    final span = end.difference(start);
    final pausedClamped = paused > span ? span : paused;
    final focused = (span - pausedClamped).inSeconds;
    _result = FocusSession(
      id: '${start.microsecondsSinceEpoch}',
      plannedSeconds: _plannedSeconds,
      startedAt: start,
      endedAt: end,
      pausedSeconds: pausedClamped.inSeconds,
      status: status == FocusStatus.stopped && focused >= _plannedSeconds
          ? FocusStatus.completed
          : status,
      workAppIds: _workAppIds,
    );
    _pauseStartedAt = null;
    _state = FocusTimerState.finished;
  }

  Duration _pausedAt(DateTime now) {
    final since = _pauseStartedAt;
    if (since == null || now.isBefore(since)) return _paused;
    return _paused + now.difference(since);
  }

  Duration _elapsedAt(DateTime now) {
    final start = _startedAt;
    if (start == null) return Duration.zero;
    final value = now.difference(start) - _pausedAt(now);
    return value.isNegative ? Duration.zero : value;
  }
}

/// What the device history says about the time of one focus session.
class FocusAppStats {
  const FocusAppStats({
    required this.distinctApps,
    required this.activeSeconds,
    required this.workSeconds,
  });

  /// Different apps that were frontmost at some point during the session.
  final int distinctApps;

  /// Active foreground time inside the session, overlaps counted once.
  final int activeSeconds;

  /// Part of [activeSeconds] spent in the apps marked as work.
  final int workSeconds;

  /// `null` when there was no active time to compare with.
  double? get workShare =>
      activeSeconds == 0 ? null : workSeconds / activeSeconds;
}

/// Clips foreground [sessions] to `[start, end)` and summarises them.
///
/// Pauses are not subtracted: the whole span of the focus session is used,
/// because history only knows app intervals, not the timer state.
FocusAppStats focusAppStats({
  required Iterable<AppSession> sessions,
  required DateTime start,
  required DateTime end,
  Set<String> workAppIds = const {},
}) {
  final from = start.toUtc(), to = end.toUtc();
  final clipped = <(DateTime, DateTime)>[];
  final work = <(DateTime, DateTime)>[];
  final apps = <String>{};
  for (final session in sessions) {
    final s = session.start.isAfter(from) ? session.start : from;
    final e = session.end.isBefore(to) ? session.end : to;
    if (!e.isAfter(s)) continue;
    apps.add(session.appId);
    clipped.add((s, e));
    if (workAppIds.contains(session.appId)) work.add((s, e));
  }
  int total(List<(DateTime, DateTime)> items) =>
      unionOf(items).fold(0, (sum, i) => sum + i.$2.difference(i.$1).inSeconds);
  return FocusAppStats(
    distinctApps: apps.length,
    activeSeconds: total(clipped),
    workSeconds: total(work),
  );
}

/// Same as [focusAppStats] for a stored [session].
FocusAppStats focusAppStatsFor(
  FocusSession session,
  Iterable<AppSession> sessions, {
  Set<String>? workAppIds,
}) => focusAppStats(
  sessions: sessions,
  start: session.startedAt,
  end: session.endedAt,
  workAppIds: workAppIds ?? session.workAppIds.toSet(),
);
