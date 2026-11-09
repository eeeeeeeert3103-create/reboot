import 'usage_data.dart';

/// Where the numbers on screen come from. Only [real] data may be recorded.
enum UsageDataMode { demo, real }

/// A calendar day in the user's local time.
///
/// Days are stored as `YYYY-MM-DD` keys, so a later time zone change never
/// moves or duplicates a day that was already recorded.
class LocalDay implements Comparable<LocalDay> {
  const LocalDay(this.year, this.month, this.day);

  factory LocalDay.fromDateTime(DateTime time) {
    final local = time.toLocal();
    return LocalDay(local.year, local.month, local.day);
  }

  factory LocalDay.today() => LocalDay.fromDateTime(DateTime.now());

  static LocalDay? tryParse(Object? key) {
    if (key is! String) return null;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(key);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return LocalDay(year, month, day);
  }

  final int year;
  final int month;
  final int day;

  String get key =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// 1 = Monday … 7 = Sunday.
  int get weekday => DateTime.utc(year, month, day).weekday;

  /// Calendar arithmetic in UTC, so daylight-saving shifts cannot skip a day.
  LocalDay addDays(int days) {
    final date = DateTime.utc(year, month, day).add(Duration(days: days));
    return LocalDay(date.year, date.month, date.day);
  }

  int daysUntil(LocalDay other) => DateTime.utc(
    other.year,
    other.month,
    other.day,
  ).difference(DateTime.utc(year, month, day)).inDays;

  @override
  int compareTo(LocalDay other) => key.compareTo(other.key);

  bool isBefore(LocalDay other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is LocalDay && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

/// One completed day of measured usage and the goal that applied to it.
class StreakDay {
  StreakDay({
    required this.day,
    required this.minutes,
    required this.goalMinutes,
  }) {
    if (minutes < 0) throw ArgumentError.value(minutes, 'minutes');
    if (goalMinutes <= 0) throw ArgumentError.value(goalMinutes, 'goalMinutes');
  }

  factory StreakDay.fromDailyUsage(DailyUsage usage, int goalMinutes) =>
      StreakDay(
        day: LocalDay.fromDateTime(usage.date),
        minutes: usage.totalMinutes,
        goalMinutes: goalMinutes,
      );

  factory StreakDay.fromMap(Map<Object?, Object?> map) {
    final day = LocalDay.tryParse(map['date']);
    final minutes = map['minutes'];
    final goal = map['goalMinutes'];
    if (day == null || minutes is! int || goal is! int) {
      throw const FormatException('Invalid streak day.');
    }
    try {
      return StreakDay(day: day, minutes: minutes, goalMinutes: goal);
    } on ArgumentError {
      throw const FormatException('Invalid streak day values.');
    }
  }

  final LocalDay day;
  final int minutes;
  final int goalMinutes;

  bool get goalMet => minutes <= goalMinutes;

  Map<String, Object> toMap() => {
    'date': day.key,
    'minutes': minutes,
    'goalMinutes': goalMinutes,
  };
}

class StreakSummary {
  StreakSummary({
    required this.today,
    required this.current,
    required this.best,
    required List<StreakDay> history,
    required this.goalMinutes,
    this.todayMinutes,
  }) : history = List.unmodifiable(history);

  static StreakSummary empty({
    required LocalDay today,
    required int goalMinutes,
  }) => StreakSummary(
    today: today,
    current: 0,
    best: 0,
    history: const [],
    goalMinutes: goalMinutes,
  );

  final LocalDay today;

  /// Completed days in a row within the goal, ending yesterday.
  final int current;
  final int best;

  /// Completed days, oldest first.
  final List<StreakDay> history;
  final int goalMinutes;
  final int? todayMinutes;

  double? get todayProgress =>
      todayMinutes == null ? null : todayMinutes! / goalMinutes;

  StreakDay? dayFor(LocalDay day) {
    for (final item in history) {
      if (item.day == day) return item;
    }
    return null;
  }
}

abstract final class StreakCalculator {
  /// Builds a summary from completed days only.
  ///
  /// Today is still in progress and is shown as daily-goal progress, not
  /// counted. Days dated today or later (for example after the clock or time
  /// zone moved back) are ignored. A missing day simply ends a run.
  static StreakSummary summarize({
    required Iterable<StreakDay> days,
    required LocalDay today,
    required int goalMinutes,
    int? todayMinutes,
  }) {
    final byDay = <LocalDay, StreakDay>{};
    for (final item in days) {
      if (item.day.isBefore(today)) byDay.putIfAbsent(item.day, () => item);
    }
    final history = byDay.values.toList()
      ..sort((a, b) => a.day.compareTo(b.day));

    var best = 0;
    var run = 0;
    LocalDay? previous;
    for (final item in history) {
      final continues = previous != null && previous.daysUntil(item.day) == 1;
      run = item.goalMet ? (continues ? run + 1 : 1) : 0;
      if (run > best) best = run;
      previous = item.day;
    }

    var current = 0;
    var cursor = today.addDays(-1);
    while (byDay[cursor]?.goalMet ?? false) {
      current++;
      cursor = cursor.addDays(-1);
    }

    return StreakSummary(
      today: today,
      current: current,
      best: best,
      history: history,
      goalMinutes: goalMinutes,
      todayMinutes: todayMinutes,
    );
  }
}

/// Preview built from demo fixtures. It is shown with a DEMO label and is
/// never written to the streak ledger.
StreakSummary demoStreakPreview(UsageOverview usage, {LocalDay? today}) =>
    StreakCalculator.summarize(
      days: [
        ...usage.previousWeek,
        ...usage.currentWeek,
      ].map((day) => StreakDay.fromDailyUsage(day, usage.dailyTargetMinutes)),
      today: today ?? LocalDay.today(),
      goalMinutes: usage.dailyTargetMinutes,
      todayMinutes: usage.todayMinutes,
    );
