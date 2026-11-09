import 'dart:math' as math;

import 'streak.dart';
import 'usage_data.dart';
import 'usage_history.dart';

/// Totals for one local calendar day.
class DayUsage {
  const DayUsage({
    required this.day,
    this.activeSeconds = 0,
    this.idleSeconds = 0,
    this.lockedSeconds = 0,
    this.launches,
    this.unlocks,
    this.coverageSeconds,
  });

  final LocalDay day;

  /// Union of foreground sessions, so overlaps are never counted twice.
  final int activeSeconds;
  final int idleSeconds;
  final int lockedSeconds;

  /// `null` when the source does not provide the value (demo fixtures).
  final int? launches;
  final int? unlocks;

  /// Seconds the collector was running in this day; `null` for demo.
  final int? coverageSeconds;

  bool get hasData => coverageSeconds == null || coverageSeconds! > 0;
  int get activeMinutes => activeSeconds ~/ 60;
}

class AppTotal {
  const AppTotal({
    required this.appId,
    required this.name,
    required this.activeSeconds,
    this.launches,
    this.sessions,
    this.longestSessionSeconds,
    this.category,
  });

  final String appId;
  final String name;
  final int activeSeconds;
  final int? launches;
  final int? sessions;
  final int? longestSessionSeconds;

  /// Only demo fixtures carry a category; real apps are not classified.
  final UsageCategoryId? category;
}

class UsageReport {
  UsageReport({
    required this.mode,
    required this.today,
    required this.goalMinutes,
    required List<DayUsage> days,
    required List<DayUsage> previousDays,
    required List<AppTotal> appsToday,
    List<AppTotal>? appsPeriod,
    this.categoriesToday,
    this.categoriesPeriod,
  }) : days = List.unmodifiable(days),
       previousDays = List.unmodifiable(previousDays),
       appsToday = List.unmodifiable(appsToday),
       appsPeriod = appsPeriod == null ? null : List.unmodifiable(appsPeriod) {
    if (days.isEmpty) throw ArgumentError('A report needs at least one day.');
    if (goalMinutes <= 0) throw ArgumentError.value(goalMinutes, 'goalMinutes');
  }

  final UsageDataMode mode;
  final LocalDay today;
  final int goalMinutes;

  /// Oldest first; the last entry is today.
  final List<DayUsage> days;

  /// The same number of days right before [days].
  final List<DayUsage> previousDays;
  final List<AppTotal> appsToday;

  /// `null` when the source has no per-app breakdown for the period.
  final List<AppTotal>? appsPeriod;

  /// Minutes per category; only demo fixtures are categorised.
  final Map<UsageCategoryId, int>? categoriesToday;
  final Map<UsageCategoryId, int>? categoriesPeriod;

  int get periodDays => days.length;
  DayUsage get todayUsage => days.last;
  DayUsage? get yesterdayUsage =>
      days.length > 1 ? days[days.length - 2] : null;

  List<DayUsage> get daysWithData => days.where((d) => d.hasData).toList();
  bool get hasAnyData =>
      days.any((d) => d.hasData && d.activeSeconds > 0) || appsToday.isNotEmpty;

  int get periodActiveSeconds => _sum(days, (d) => d.activeSeconds);
  int get previousActiveSeconds => _sum(previousDays, (d) => d.activeSeconds);
  int get periodIdleSeconds => _sum(days, (d) => d.idleSeconds);
  int? get periodLaunches => days.any((d) => d.launches == null)
      ? null
      : _sum(days, (d) => d.launches!);

  /// Average over days that have data, never over empty days.
  int get averageActiveSeconds {
    final withData = daysWithData;
    return withData.isEmpty
        ? 0
        : (_sum(withData, (d) => d.activeSeconds) / withData.length).round();
  }

  /// Days with data whose active time stayed within the goal.
  int get daysWithinGoal =>
      daysWithData.where((d) => d.activeSeconds <= goalMinutes * 60).length;

  /// `null` when either period has no data to compare.
  double? get changeFraction {
    final previous = previousActiveSeconds;
    if (previous == 0 || !previousDays.any((d) => d.hasData)) return null;
    if (!days.any((d) => d.hasData)) return null;
    return (periodActiveSeconds - previous) / previous;
  }

  double get todayGoalProgress => todayUsage.activeSeconds / (goalMinutes * 60);

  static int _sum(Iterable<DayUsage> days, int Function(DayUsage) pick) =>
      days.fold(0, (sum, day) => sum + pick(day));
}

/// Splits `[start, end)` at local midnights and returns seconds per day.
Map<LocalDay, int> splitByLocalDay(DateTime start, DateTime end) {
  final result = <LocalDay, int>{};
  var cursor = start.toLocal();
  final stop = end.toLocal();
  while (cursor.isBefore(stop)) {
    final nextMidnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
    final pieceEnd = nextMidnight.isBefore(stop) ? nextMidnight : stop;
    final day = LocalDay.fromDateTime(cursor);
    result[day] = (result[day] ?? 0) + pieceEnd.difference(cursor).inSeconds;
    cursor = pieceEnd;
  }
  return result;
}

/// Splits `[start, end)` at local hour boundaries: (day, hour) → seconds.
Map<(LocalDay, int), int> splitByLocalHour(DateTime start, DateTime end) {
  final result = <(LocalDay, int), int>{};
  var cursor = start.toLocal();
  final stop = end.toLocal();
  while (cursor.isBefore(stop)) {
    final nextHour = DateTime(
      cursor.year,
      cursor.month,
      cursor.day,
      cursor.hour + 1,
    );
    final pieceEnd = nextHour.isBefore(stop) ? nextHour : stop;
    final key = (LocalDay.fromDateTime(cursor), cursor.hour);
    result[key] = (result[key] ?? 0) + pieceEnd.difference(cursor).inSeconds;
    cursor = pieceEnd;
  }
  return result;
}

/// Weekday × hour grid of active seconds.
class ActivityHeatmap {
  const ActivityHeatmap({required this.cells, required this.coveredDays});

  /// `cells[weekday - 1][hour]`, summed over the period.
  final List<List<int>> cells;

  /// Days with collection coverage per weekday; used for averages.
  final List<int> coveredDays;

  int get maxCell =>
      cells.fold(0, (m, row) => row.fold(m, (m2, v) => v > m2 ? v : m2));

  bool get isEmpty => maxCell == 0;

  /// Average seconds of activity in that hour per covered day of that weekday.
  int average(int weekdayIndex, int hour) => coveredDays[weekdayIndex] == 0
      ? 0
      : cells[weekdayIndex][hour] ~/ coveredDays[weekdayIndex];

  int get totalSeconds =>
      cells.fold(0, (sum, row) => sum + row.fold(0, (a, b) => a + b));

  /// Seconds per hour of day across all weekdays.
  List<int> get byHour => [
    for (var h = 0; h < 24; h++) cells.fold(0, (sum, row) => sum + row[h]),
  ];

  /// Seconds per weekday across all hours.
  List<int> get byWeekday => [
    for (final row in cells) row.fold(0, (a, b) => a + b),
  ];
}

/// Merges overlapping intervals so shared time is counted once.
List<(DateTime, DateTime)> unionOf(Iterable<(DateTime, DateTime)> intervals) {
  final sorted = intervals.where((i) => i.$2.isAfter(i.$1)).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(DateTime, DateTime)>[];
  for (final item in sorted) {
    if (merged.isNotEmpty && !item.$1.isAfter(merged.last.$2)) {
      final last = merged.removeLast();
      merged.add((last.$1, item.$2.isAfter(last.$2) ? item.$2 : last.$2));
    } else {
      merged.add(item);
    }
  }
  return merged;
}

Map<LocalDay, int> _secondsPerDay(Iterable<(DateTime, DateTime)> intervals) {
  final result = <LocalDay, int>{};
  for (final (start, end) in unionOf(intervals)) {
    splitByLocalDay(start, end).forEach((day, seconds) {
      result[day] = (result[day] ?? 0) + seconds;
    });
  }
  return result;
}

/// Day totals for every local day that appears in [history].
class HistoryIndex {
  HistoryIndex({
    required List<AppSession> sessions,
    required List<AppLaunch> launches,
    required List<TimeInterval> intervals,
  }) : _sessions = [
         for (final s in sessions)
           if (!isSelfApp(s.appId)) s,
       ],
       _launches = [
         for (final l in launches)
           if (!isSelfApp(l.appId)) l,
       ],
       _intervals = intervals {
    _active = _secondsPerDay(_sessions.map((s) => (s.start, s.end)));
    _idle = _secondsPerDay(
      intervals
          .where((i) => i.kind == IntervalKind.idle)
          .map((i) => (i.start, i.end)),
    );
    _locked = _secondsPerDay(
      intervals
          .where((i) => i.kind == IntervalKind.locked)
          .map((i) => (i.start, i.end)),
    );
    _coverage = _secondsPerDay(
      intervals
          .where((i) => i.kind == IntervalKind.coverage)
          .map((i) => (i.start, i.end)),
    );
    for (final launch in _launches) {
      final day = LocalDay.fromDateTime(launch.at);
      _launchCount[day] = (_launchCount[day] ?? 0) + 1;
    }
    for (final lock in intervals.where((i) => i.kind == IntervalKind.locked)) {
      final day = LocalDay.fromDateTime(lock.end);
      _unlockCount[day] = (_unlockCount[day] ?? 0) + 1;
    }
  }

  final List<AppSession> _sessions;
  final List<AppLaunch> _launches;
  final List<TimeInterval> _intervals;
  late final Map<LocalDay, int> _active, _idle, _locked, _coverage;
  final _launchCount = <LocalDay, int>{};
  final _unlockCount = <LocalDay, int>{};

  DayUsage day(LocalDay day) => DayUsage(
    day: day,
    activeSeconds: _active[day] ?? 0,
    idleSeconds: _idle[day] ?? 0,
    lockedSeconds: _locked[day] ?? 0,
    launches: _launchCount[day] ?? 0,
    unlocks: _unlockCount[day] ?? 0,
    coverageSeconds: _coverage[day] ?? 0,
  );

  Iterable<LocalDay> get coveredDays => _coverage.keys;

  /// All stored sessions, oldest first (read-only).
  List<AppSession> get sessions => List.unmodifiable(_sessions);

  /// Per-app totals for local days in `[from, to]`, longest first.
  List<AppTotal> apps(LocalDay from, LocalDay to) {
    bool inRange(LocalDay d) => !d.isBefore(from) && !to.isBefore(d);
    final pieces = <String, List<(DateTime, DateTime)>>{};
    final names = <String, String>{};
    final sessionCount = <String, int>{};
    final longest = <String, int>{};
    for (final session in _sessions) {
      final split = splitByLocalDay(session.start, session.end);
      if (!split.keys.any(inRange)) continue;
      names[session.appId] = session.appName;
      sessionCount[session.appId] = (sessionCount[session.appId] ?? 0) + 1;
      longest[session.appId] = math.max(
        longest[session.appId] ?? 0,
        session.duration.inSeconds,
      );
      pieces.putIfAbsent(session.appId, () => []).add((
        session.start,
        session.end,
      ));
    }
    final launches = <String, int>{};
    for (final launch in _launches) {
      if (!inRange(LocalDay.fromDateTime(launch.at))) continue;
      names.putIfAbsent(launch.appId, () => launch.appName);
      launches[launch.appId] = (launches[launch.appId] ?? 0) + 1;
    }
    final totals = [
      for (final appId in names.keys)
        AppTotal(
          appId: appId,
          name: names[appId]!,
          activeSeconds: _secondsPerDay(pieces[appId] ?? const []).entries
              .where((e) => inRange(e.key))
              .fold(0, (sum, e) => sum + e.value),
          launches: launches[appId] ?? 0,
          sessions: sessionCount[appId] ?? 0,
          longestSessionSeconds: longest[appId] ?? 0,
        ),
    ]..sort((a, b) => b.activeSeconds.compareTo(a.activeSeconds));
    return totals
        .where((a) => a.activeSeconds > 0 || (a.launches ?? 0) > 0)
        .toList();
  }

  /// Per-day active seconds of one app for `[from, to]`.
  List<(LocalDay, int)> appDaily(String appId, LocalDay from, LocalDay to) {
    final perDay = _secondsPerDay(
      _sessions.where((s) => s.appId == appId).map((s) => (s.start, s.end)),
    );
    return [
      for (var d = from; !to.isBefore(d); d = d.addDays(1)) (d, perDay[d] ?? 0),
    ];
  }

  /// Sessions overlapping `[start, end)`, clipped to it, oldest first.
  List<AppSession> sessionsIn(DateTime start, DateTime end, {String? appId}) {
    final from = start.toUtc(), to = end.toUtc();
    return [
      for (final s in _sessions)
        if ((appId == null || s.appId == appId) &&
            s.start.isBefore(to) &&
            from.isBefore(s.end))
          AppSession(
            appId: s.appId,
            appName: s.appName,
            start: s.start.isBefore(from) ? from : s.start,
            end: s.end.isAfter(to) ? to : s.end,
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Idle, locked or coverage periods overlapping `[start, end)`, clipped.
  List<TimeInterval> intervalsIn(
    DateTime start,
    DateTime end,
    IntervalKind kind,
  ) {
    final from = start.toUtc(), to = end.toUtc();
    final merged = unionOf([
      for (final i in _intervals)
        if (i.kind == kind && i.start.isBefore(to) && from.isBefore(i.end))
          (
            i.start.isBefore(from) ? from : i.start,
            i.end.isAfter(to) ? to : i.end,
          ),
    ]);
    return [
      for (final (a, b) in merged) TimeInterval(kind: kind, start: a, end: b),
    ];
  }

  /// Launches in local days `[from, to]`.
  List<AppLaunch> launchesIn(LocalDay from, LocalDay to, {String? appId}) => [
    for (final l in _launches)
      if ((appId == null || l.appId == appId) &&
          !LocalDay.fromDateTime(l.at).isBefore(from) &&
          !to.isBefore(LocalDay.fromDateTime(l.at)))
        l,
  ];

  /// Active seconds per local hour (0–23) of [day].
  List<int> hourly(LocalDay day, {String? appId}) {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    final hours = List<int>.filled(24, 0);
    final pieces = unionOf(
      sessionsIn(start, end, appId: appId).map((s) => (s.start, s.end)),
    );
    for (final (a, b) in pieces) {
      splitByLocalHour(a, b).forEach((key, seconds) {
        if (key.$1 == day) hours[key.$2] += seconds;
      });
    }
    return hours;
  }

  /// Weekday (0 = Monday) × hour active seconds summed over `[from, to]`,
  /// plus how many days of each weekday had collection coverage.
  ActivityHeatmap heatmap(LocalDay from, LocalDay to, {String? appId}) {
    final cells = List.generate(7, (_) => List<int>.filled(24, 0));
    final coveredDays = List<int>.filled(7, 0);
    for (var d = from; !to.isBefore(d); d = d.addDays(1)) {
      if ((_coverage[d] ?? 0) == 0) continue;
      coveredDays[d.weekday - 1]++;
      final hours = hourly(d, appId: appId);
      for (var h = 0; h < 24; h++) {
        cells[d.weekday - 1][h] += hours[h];
      }
    }
    return ActivityHeatmap(cells: cells, coveredDays: coveredDays);
  }

  /// Distinct apps that appear in history, most used first.
  List<AppTotal> allApps() {
    if (_sessions.isEmpty && _launches.isEmpty) return const [];
    final days = [
      ..._sessions.map((s) => LocalDay.fromDateTime(s.start)),
      ..._launches.map((l) => LocalDay.fromDateTime(l.at)),
    ]..sort();
    return apps(days.first, days.last);
  }

  /// Finished days with enough coverage to be judged against the goal.
  List<StreakDay> completedStreakDays({
    required LocalDay today,
    required int goalMinutes,
    int minCoverageSeconds = minStreakCoverageSeconds,
  }) => [
    for (final day in coveredDays.toList()..sort())
      if (day.isBefore(today) && (_coverage[day] ?? 0) >= minCoverageSeconds)
        StreakDay(
          day: day,
          minutes: (_active[day] ?? 0) ~/ 60,
          goalMinutes: goalMinutes,
        ),
  ];
}

/// A day counts for the streak only when REBOOT was collecting for at least
/// this long in it; otherwise usage outside REBOOT is unknown.
const minStreakCoverageSeconds = 12 * 3600;

UsageReport buildRealReport({
  required HistoryIndex index,
  required LocalDay today,
  required int goalMinutes,
  int periodDays = 7,
}) {
  final first = today.addDays(-(periodDays - 1));
  final previousFirst = first.addDays(-periodDays);
  return UsageReport(
    mode: UsageDataMode.real,
    today: today,
    goalMinutes: goalMinutes,
    days: [for (var i = 0; i < periodDays; i++) index.day(first.addDays(i))],
    previousDays: [
      for (var i = 0; i < periodDays; i++) index.day(previousFirst.addDays(i)),
    ],
    appsToday: index.apps(today, today),
    appsPeriod: index.apps(first, today),
  );
}

/// Report for any local-day range `[from, to]`; the previous period is the
/// same number of days right before [from].
UsageReport buildRangeReport({
  required HistoryIndex index,
  required LocalDay from,
  required LocalDay to,
  required int goalMinutes,
}) {
  final count = from.daysUntil(to) + 1;
  if (count < 1) throw ArgumentError('Range must contain at least one day.');
  final previousFirst = from.addDays(-count);
  return UsageReport(
    mode: UsageDataMode.real,
    today: to,
    goalMinutes: goalMinutes,
    days: [for (var i = 0; i < count; i++) index.day(from.addDays(i))],
    previousDays: [
      for (var i = 0; i < count; i++) index.day(previousFirst.addDays(i)),
    ],
    appsToday: index.apps(to, to),
    appsPeriod: index.apps(from, to),
  );
}

/// Wraps the prepared demo fixtures. Launches, unlocks and coverage are
/// `null` because the fixtures do not contain them.
UsageReport buildDemoReport(UsageOverview overview) {
  DayUsage toDay(DailyUsage d) => DayUsage(
    day: LocalDay.fromDateTime(d.date),
    activeSeconds: d.totalMinutes * 60,
  );
  return UsageReport(
    mode: UsageDataMode.demo,
    today: LocalDay.fromDateTime(overview.today.date),
    goalMinutes: overview.dailyTargetMinutes,
    days: overview.currentWeek.map(toDay).toList(),
    previousDays: overview.previousWeek.map(toDay).toList(),
    appsToday: [
      for (final app in overview.appsToday)
        AppTotal(
          appId: app.name.toLowerCase(),
          name: app.name,
          activeSeconds: app.minutes * 60,
          category: app.category,
        ),
    ],
    categoriesToday: overview.todayByCategory,
    categoriesPeriod: overview.currentWeekByCategory,
  );
}
