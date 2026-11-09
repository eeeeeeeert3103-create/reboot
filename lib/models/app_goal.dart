import 'streak.dart';
import 'usage_report.dart';

/// A daily time limit the user set for one app.
///
/// Shows progress and, if [warnEnabled], an in-app reminder. With
/// [softLimit] REBOOT also hides (macOS) or minimises (Windows) the app
/// when it is in front after the limit is used up. Nothing is closed and
/// launching is never blocked.
class AppGoal {
  AppGoal({
    required this.appId,
    required this.appName,
    required this.dailyLimitMinutes,
    this.warnEnabled = true,
    this.softLimit = false,
    required DateTime createdAt,
  }) : createdAt = createdAt.toUtc() {
    if (appId.trim().isEmpty) throw ArgumentError.value(appId, 'appId');
    if (dailyLimitMinutes < minLimitMinutes ||
        dailyLimitMinutes > maxLimitMinutes) {
      throw ArgumentError.value(dailyLimitMinutes, 'dailyLimitMinutes');
    }
  }

  factory AppGoal.fromMap(Map<Object?, Object?> map) {
    final app = map['app'], name = map['name'];
    final limit = map['dailyLimitMinutes'], warn = map['warn'];
    final created = map['createdAt'];
    final createdAt = created is String ? DateTime.tryParse(created) : null;
    if (app is! String ||
        name is! String ||
        limit is! int ||
        warn is! bool ||
        createdAt == null) {
      throw const FormatException('Invalid app goal.');
    }
    try {
      return AppGoal(
        appId: app,
        appName: name,
        dailyLimitMinutes: limit,
        warnEnabled: warn,
        // Older files have no key: soft limit stays off.
        softLimit: map['softLimit'] == true,
        createdAt: createdAt,
      );
    } on ArgumentError {
      throw const FormatException('Invalid app goal values.');
    }
  }

  static const minLimitMinutes = 5;
  static const maxLimitMinutes = 600;

  final String appId;
  final String appName;
  final int dailyLimitMinutes;
  final bool warnEnabled;
  final bool softLimit;
  final DateTime createdAt;

  int get dailyLimitSeconds => dailyLimitMinutes * 60;

  AppGoal copyWith({
    int? dailyLimitMinutes,
    bool? warnEnabled,
    bool? softLimit,
  }) => AppGoal(
    appId: appId,
    appName: appName,
    dailyLimitMinutes: dailyLimitMinutes ?? this.dailyLimitMinutes,
    warnEnabled: warnEnabled ?? this.warnEnabled,
    softLimit: softLimit ?? this.softLimit,
    createdAt: createdAt,
  );

  Map<String, Object> toMap() => {
    'app': appId,
    'name': appName,
    'dailyLimitMinutes': dailyLimitMinutes,
    'warn': warnEnabled,
    'softLimit': softLimit,
    'createdAt': createdAt.toIso8601String(),
  };
}

enum AppGoalStatus {
  /// Below 80% of the limit.
  ok,

  /// At least 80% of the limit.
  near,

  /// The limit is used up.
  reached,
}

enum GoalDayResult {
  /// Usage stayed within the limit.
  met,
  exceeded,

  /// REBOOT was not collecting that day, so usage is unknown.
  noData,
}

class AppGoalDay {
  const AppGoalDay({
    required this.day,
    required this.usedSeconds,
    required this.result,
  });

  final LocalDay day;
  final int usedSeconds;
  final GoalDayResult result;
}

AppGoalStatus goalStatusFor(double fraction) => fraction >= 1
    ? AppGoalStatus.reached
    : fraction >= .8
    ? AppGoalStatus.near
    : AppGoalStatus.ok;

/// Progress of one goal, computed from REAL history only.
class AppGoalProgress {
  AppGoalProgress._({
    required this.goal,
    required this.today,
    required this.usedSeconds,
    required List<AppGoalDay> history,
  }) : history = List.unmodifiable(history);

  static const historyDays = 14;

  /// Today's usage and the last [historyDays] finished days (today excluded).
  factory AppGoalProgress.compute({
    required AppGoal goal,
    required HistoryIndex index,
    required LocalDay today,
  }) {
    final from = today.addDays(-historyDays);
    final daily = index.appDaily(goal.appId, from, today);
    final history = <AppGoalDay>[];
    var used = 0;
    for (final (day, seconds) in daily) {
      if (day == today) {
        used = seconds;
        continue;
      }
      final covered = (index.day(day).coverageSeconds ?? 0) > 0;
      history.add(
        AppGoalDay(
          day: day,
          usedSeconds: seconds,
          result: !covered
              ? GoalDayResult.noData
              : seconds <= goal.dailyLimitSeconds
              ? GoalDayResult.met
              : GoalDayResult.exceeded,
        ),
      );
    }
    return AppGoalProgress._(
      goal: goal,
      today: today,
      usedSeconds: used,
      history: history,
    );
  }

  final AppGoal goal;
  final LocalDay today;
  final int usedSeconds;

  /// Finished days, oldest first.
  final List<AppGoalDay> history;

  double get fraction => usedSeconds / goal.dailyLimitSeconds;
  AppGoalStatus get status => goalStatusFor(fraction);
  int get remainingSeconds {
    final left = goal.dailyLimitSeconds - usedSeconds;
    return left < 0 ? 0 : left;
  }

  int get metDays => history.where((d) => d.result == GoalDayResult.met).length;
  int get daysWithData =>
      history.where((d) => d.result != GoalDayResult.noData).length;
}

/// An in-app reminder that a goal is near or reached. Not a system
/// notification; the app shows it as a banner or SnackBar.
class AppGoalAlert {
  const AppGoalAlert({
    required this.goal,
    required this.day,
    required this.status,
    required this.usedSeconds,
  });

  final AppGoal goal;
  final LocalDay day;

  /// [AppGoalStatus.near] or [AppGoalStatus.reached].
  final AppGoalStatus status;
  final int usedSeconds;

  /// Stable key: the caller remembers it so the alert is shown once a day.
  String get key => alertKey(goal.appId, day, status);

  static String alertKey(String appId, LocalDay day, AppGoalStatus status) =>
      '$appId|${day.key}|${status.name}';

  String get message => switch (status) {
    AppGoalStatus.reached =>
      '${goal.appName}: дневная цель достигнута '
          '(${usedSeconds ~/ 60} из ${goal.dailyLimitMinutes} мин).',
    _ =>
      '${goal.appName}: использовано ${usedSeconds ~/ 60} из '
          '${goal.dailyLimitMinutes} мин — больше 80% цели.',
  };
}

/// Reminders to show now for [today].
///
/// Each threshold is reported at most once per day per app (keys from
/// [AppGoalAlert.key] the caller already showed are passed in
/// [alreadyShown]) and only for goals with warnings on. When the limit is
/// already reached, only the "reached" reminder is returned. With no REAL
/// history ([index] is `null`) nothing is returned.
List<AppGoalAlert> pendingAlerts(
  Iterable<AppGoal> goals,
  HistoryIndex? index,
  LocalDay today,
  Set<String> alreadyShown,
) {
  if (index == null) return const [];
  final alerts = <AppGoalAlert>[];
  for (final goal in goals) {
    if (!goal.warnEnabled) continue;
    final used = index.appDaily(goal.appId, today, today).single.$2;
    final status = goalStatusFor(used / goal.dailyLimitSeconds);
    if (status == AppGoalStatus.ok) continue;
    if (alreadyShown.contains(
      AppGoalAlert.alertKey(goal.appId, today, AppGoalStatus.reached),
    )) {
      continue;
    }
    if (status == AppGoalStatus.near &&
        alreadyShown.contains(
          AppGoalAlert.alertKey(goal.appId, today, AppGoalStatus.near),
        )) {
      continue;
    }
    alerts.add(
      AppGoalAlert(goal: goal, day: today, status: status, usedSeconds: used),
    );
  }
  return alerts;
}

/// Goals whose soft limit is used up today, excluding apps the user
/// snoozed (until a moment) or released for the day.
List<AppGoal> exhaustedSoftLimits({
  required Iterable<AppGoal> goals,
  required HistoryIndex index,
  required LocalDay today,
  required DateTime now,
  Map<String, DateTime> snoozedUntil = const {},
  Set<String> releasedToday = const {},
}) => [
  for (final goal in goals)
    if (goal.softLimit &&
        !releasedToday.contains(goal.appId) &&
        !(snoozedUntil[goal.appId]?.isAfter(now) ?? false) &&
        index.appDaily(goal.appId, today, today).single.$2 >=
            goal.dailyLimitSeconds)
      goal,
];
