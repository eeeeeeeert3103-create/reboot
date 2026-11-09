import 'collector_models.dart';

/// Locally stored usage records built from collector events.
///
/// Everything here is a time interval or an instant in UTC. Grouping into
/// local days happens when reports are built, so a time zone change regroups
/// history instead of corrupting it.

DateTime? _parseTime(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String _time(DateTime value) => value.toUtc().toIso8601String();

/// REBOOT's own identifiers on macOS and Windows. Time spent in REBOOT is
/// not part of the user's statistics.
const selfAppIds = {'com.reboot.app.rebootApp', 'reboot_app.exe'};

bool isSelfApp(String? appId) => appId != null && selfAppIds.contains(appId);

/// One continuous stretch of an app being frontmost while the user was active.
class AppSession {
  AppSession({
    required this.appId,
    required this.appName,
    required DateTime start,
    required DateTime end,
  }) : start = start.toUtc(),
       end = end.toUtc() {
    if (appId.trim().isEmpty) throw ArgumentError.value(appId, 'appId');
    if (!this.end.isAfter(this.start)) {
      throw ArgumentError('Session must end after it starts.');
    }
  }

  final String appId;
  final String appName;
  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
  String get key =>
      '$appId|${start.millisecondsSinceEpoch}|${end.millisecondsSinceEpoch}';

  AppSession copyWith({DateTime? end}) => AppSession(
    appId: appId,
    appName: appName,
    start: start,
    end: end ?? this.end,
  );

  Map<String, Object> toMap() => {
    'app': appId,
    'name': appName,
    'start': _time(start),
    'end': _time(end),
  };

  factory AppSession.fromMap(Map<Object?, Object?> map) {
    final app = map['app'], name = map['name'];
    final start = _parseTime(map['start']), end = _parseTime(map['end']);
    if (app is! String || name is! String || start == null || end == null) {
      throw const FormatException('Invalid session record.');
    }
    try {
      return AppSession(appId: app, appName: name, start: start, end: end);
    } on ArgumentError {
      throw const FormatException('Invalid session values.');
    }
  }
}

class AppLaunch {
  AppLaunch({required this.appId, required this.appName, required DateTime at})
    : at = at.toUtc();

  final String appId;
  final String appName;
  final DateTime at;

  String get key => '$appId|${at.millisecondsSinceEpoch}';

  Map<String, Object> toMap() => {
    'app': appId,
    'name': appName,
    'at': _time(at),
  };

  factory AppLaunch.fromMap(Map<Object?, Object?> map) {
    final app = map['app'], name = map['name'];
    final at = _parseTime(map['at']);
    if (app is! String || app.isEmpty || name is! String || at == null) {
      throw const FormatException('Invalid launch record.');
    }
    return AppLaunch(appId: app, appName: name, at: at);
  }
}

enum IntervalKind {
  /// No user input for the idle threshold.
  idle,

  /// Screen locked, session switched away or system asleep.
  locked,

  /// The collector was running (REBOOT open and collecting).
  coverage,
}

class TimeInterval {
  TimeInterval({
    required this.kind,
    required DateTime start,
    required DateTime end,
  }) : start = start.toUtc(),
       end = end.toUtc() {
    if (this.end.isBefore(this.start)) {
      throw ArgumentError('Interval must not end before it starts.');
    }
  }

  final IntervalKind kind;
  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
  String get key =>
      '${kind.name}|${start.millisecondsSinceEpoch}|${end.millisecondsSinceEpoch}';

  Map<String, Object> toMap() => {
    'kind': kind.name,
    'start': _time(start),
    'end': _time(end),
  };

  factory TimeInterval.fromMap(Map<Object?, Object?> map) {
    final kind = IntervalKind.values.where((k) => k.name == map['kind']);
    final start = _parseTime(map['start']), end = _parseTime(map['end']);
    if (kind.isEmpty || start == null || end == null) {
      throw const FormatException('Invalid interval record.');
    }
    try {
      return TimeInterval(kind: kind.single, start: start, end: end);
    } on ArgumentError {
      throw const FormatException('Invalid interval values.');
    }
  }
}

/// What one drain added to history.
class HistoryBatch {
  const HistoryBatch({
    this.sessions = const [],
    this.launches = const [],
    this.intervals = const [],
    this.inactiveWindows = const [],
  });

  final List<AppSession> sessions;
  final List<AppLaunch> launches;
  final List<TimeInterval> intervals;

  /// Periods the user was idle; any stored active time inside them is removed.
  /// Needed because idle is detected only after the threshold, when earlier
  /// checkpoint pieces of that period were already drained.
  final List<(DateTime, DateTime)> inactiveWindows;

  bool get isEmpty =>
      sessions.isEmpty &&
      launches.isEmpty &&
      intervals.isEmpty &&
      inactiveWindows.isEmpty;
}

/// Turns collector events into history records.
///
/// Keeps the start of an idle or locked period open across drains. Repeated
/// events (for example a second `sessionLocked` without an unlock) are
/// ignored instead of opening a second period.
class EventIngestor {
  DateTime? _idleSince;
  DateTime? _lockedSince;

  HistoryBatch ingest(CollectorSnapshot snapshot) {
    final sessions = <AppSession>[];
    final launches = <AppLaunch>[];
    final intervals = <TimeInterval>[];
    final windows = <(DateTime, DateTime)>[];
    final events = [...snapshot.events]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final event in events) {
      final at = event.timestamp.toUtc();
      switch (event.type) {
        case UsageEventType.foregroundEnded:
          final seconds = event.durationSeconds ?? 0;
          final app = event.appIdentifier;
          if (seconds <= 0 || app == null || isSelfApp(app)) break;
          sessions.add(
            AppSession(
              appId: app,
              appName: event.displayName ?? app,
              start: at.subtract(Duration(seconds: seconds)),
              end: at,
            ),
          );
        case UsageEventType.appLaunched:
          final app = event.appIdentifier;
          if (app == null || isSelfApp(app)) break;
          launches.add(
            AppLaunch(appId: app, appName: event.displayName ?? app, at: at),
          );
        case UsageEventType.idleStarted:
          _idleSince ??= at;
          final ended = events
              .where(
                (e) =>
                    e.type == UsageEventType.idleEnded &&
                    !e.timestamp.isBefore(at),
              )
              .map((e) => e.timestamp.toUtc())
              .firstOrNull;
          windows.add((at, ended ?? snapshot.capturedAt.toUtc()));
        case UsageEventType.idleEnded:
          final since = _idleSince;
          _idleSince = null;
          if (since != null && at.isAfter(since)) {
            intervals.add(
              TimeInterval(kind: IntervalKind.idle, start: since, end: at),
            );
          }
        case UsageEventType.sessionLocked:
          _lockedSince ??= at;
        case UsageEventType.sessionUnlocked:
          final since = _lockedSince;
          _lockedSince = null;
          if (since != null && at.isAfter(since)) {
            intervals.add(
              TimeInterval(kind: IntervalKind.locked, start: since, end: at),
            );
          }
        case UsageEventType.foregroundStarted:
          break;
      }
    }
    return HistoryBatch(
      sessions: sessions,
      launches: launches,
      intervals: intervals,
      inactiveWindows: windows,
    );
  }

  /// Called when collection stops, so an idle or lock period that never got
  /// its end event does not stay open forever.
  HistoryBatch close(DateTime now) {
    final intervals = <TimeInterval>[
      if (_idleSince case final since? when now.isAfter(since))
        TimeInterval(kind: IntervalKind.idle, start: since, end: now),
      if (_lockedSince case final since? when now.isAfter(since))
        TimeInterval(kind: IntervalKind.locked, start: since, end: now),
    ];
    _idleSince = null;
    _lockedSince = null;
    return HistoryBatch(intervals: intervals);
  }
}
