import 'package:flutter/material.dart';

/// Numeric category identifiers stay independent of presentation labels.
enum UsageCategoryId { social, work, video, other }

class DailyUsage {
  DailyUsage({
    required this.date,
    required this.totalMinutes,
    required Map<UsageCategoryId, int> minutes,
  }) : minutes = Map.unmodifiable(minutes) {
    if (minutes.values.any((value) => value < 0)) {
      throw ArgumentError('Usage minutes cannot be negative.');
    }
    final categoryTotal = minutes.values.fold<int>(
      0,
      (sum, value) => sum + value,
    );
    if (totalMinutes < 0 || totalMinutes != categoryTotal) {
      throw ArgumentError('Daily total must equal the sum of its categories.');
    }
  }

  final DateTime date;
  final int totalMinutes;
  final Map<UsageCategoryId, int> minutes;
}

class AppUsage {
  const AppUsage({
    required this.name,
    required this.category,
    required this.minutes,
    required this.icon,
    required this.color,
  });

  final String name;
  final UsageCategoryId category;
  final int minutes;
  final IconData icon;
  final Color color;
}

class UsageOverview {
  UsageOverview({
    required this.dailyTargetMinutes,
    required List<DailyUsage> currentWeek,
    required List<DailyUsage> previousWeek,
    required this.appsToday,
  }) : currentWeek = List.unmodifiable(currentWeek),
       previousWeek = List.unmodifiable(previousWeek) {
    if (dailyTargetMinutes <= 0) {
      throw ArgumentError.value(dailyTargetMinutes, 'dailyTargetMinutes');
    }
    if (this.currentWeek.isEmpty || this.previousWeek.isEmpty) {
      throw ArgumentError('Both weekly periods must contain data.');
    }
  }

  final int dailyTargetMinutes;
  final List<DailyUsage> currentWeek;
  final List<DailyUsage> previousWeek;
  final List<AppUsage> appsToday;

  DailyUsage get today => currentWeek.last;
  int get todayMinutes => today.totalMinutes;
  int get yesterdayMinutes => currentWeek.length > 1
      ? currentWeek[currentWeek.length - 2].totalMinutes
      : todayMinutes;
  int get currentWeekMinutes => _sum(currentWeek);
  int get previousWeekMinutes => _sum(previousWeek);
  int get averagePerDayMinutes =>
      (currentWeekMinutes / currentWeek.length).round();
  int get daysAtOrBelowTarget =>
      currentWeek.where((day) => day.totalMinutes <= dailyTargetMinutes).length;
  double? get weekChangeFraction => previousWeekMinutes == 0
      ? null
      : (currentWeekMinutes - previousWeekMinutes) / previousWeekMinutes;
  double get todayGoalProgress => todayMinutes / dailyTargetMinutes;
  int get minutesToGoal => dailyTargetMinutes - todayMinutes;

  Map<UsageCategoryId, int> get todayByCategory => _categoryTotals([today]);
  Map<UsageCategoryId, int> get currentWeekByCategory =>
      _categoryTotals(currentWeek);

  UsageOverview withTarget(int targetMinutes) => UsageOverview(
    dailyTargetMinutes: targetMinutes,
    currentWeek: currentWeek,
    previousWeek: previousWeek,
    appsToday: appsToday,
  );

  static int _sum(List<DailyUsage> days) =>
      days.fold(0, (sum, day) => sum + day.totalMinutes);

  static Map<UsageCategoryId, int> _categoryTotals(List<DailyUsage> days) {
    return {
      for (final category in UsageCategoryId.values)
        category: days.fold(
          0,
          (sum, day) => sum + (day.minutes[category] ?? 0),
        ),
    };
  }
}

enum UsageSourceState { demo, loading, empty, permissionDenied }

class UsageCategory {
  const UsageCategory({
    required this.id,
    required this.name,
    required this.icon,
  });
  final UsageCategoryId id;
  final String name;
  final IconData icon;
}

const usageCategories = [
  UsageCategory(
    id: UsageCategoryId.social,
    name: 'Соцсети',
    icon: Icons.forum_rounded,
  ),
  UsageCategory(
    id: UsageCategoryId.work,
    name: 'Работа',
    icon: Icons.work_outline_rounded,
  ),
  UsageCategory(
    id: UsageCategoryId.video,
    name: 'Видео',
    icon: Icons.play_circle_outline_rounded,
  ),
  UsageCategory(
    id: UsageCategoryId.other,
    name: 'Другое',
    icon: Icons.grid_view_rounded,
  ),
];

String formatMinutes(int value) {
  final hours = value ~/ 60;
  final minutes = value % 60;
  if (hours == 0) return '$minutes мин';
  if (minutes == 0) return '$hours ч';
  return '$hours ч $minutes мин';
}

/// Durations from seconds: "45 с", "12 мин", "2 ч 05 мин".
String formatDuration(int seconds) {
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return '$seconds с';
  final totalMinutes = seconds ~/ 60;
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '$minutes мин';
  return '$hours ч ${minutes.toString().padLeft(2, '0')} мин';
}

/// Compact clock-like duration for dense columns: "0:45", "2:05".
String formatHoursMinutes(int seconds) {
  final totalMinutes = (seconds < 0 ? 0 : seconds) ~/ 60;
  return '${totalMinutes ~/ 60}:${(totalMinutes % 60).toString().padLeft(2, '0')}';
}

String formatPercent(double value, {bool signed = false}) {
  final rounded = (value * 100).round();
  final sign = signed && rounded > 0 ? '+' : '';
  return '$sign$rounded%';
}

UsageOverview? _demoUsage;
String? _demoUsageDay;

/// Demo fixtures anchored to the current local date; rebuilt after midnight
/// so a long-running app never shows yesterday as "today".
UsageOverview get demoUsage {
  final now = DateTime.now();
  final day = '${now.year}-${now.month}-${now.day}';
  if (_demoUsageDay != day || _demoUsage == null) {
    _demoUsage = _buildDemoUsage();
    _demoUsageDay = day;
  }
  return _demoUsage!;
}

UsageOverview _buildDemoUsage() {
  const currentTotals = [306, 378, 342, 420, 324, 378, 342];
  const previousTotals = [372, 408, 366, 444, 402, 420, 378];
  final today = DateTime.now();
  final start = DateTime(
    today.year,
    today.month,
    today.day,
  ).subtract(const Duration(days: 6));

  DailyUsage makeDay(DateTime date, int total, {bool today = false}) {
    if (today) {
      return DailyUsage(
        date: date,
        totalMinutes: total,
        minutes: const {
          UsageCategoryId.social: 108,
          UsageCategoryId.work: 92,
          UsageCategoryId.video: 66,
          UsageCategoryId.other: 76,
        },
      );
    }
    final social = (total * .316).round();
    final work = (total * .27).round();
    final video = (total * .193).round();
    return DailyUsage(
      date: date,
      totalMinutes: total,
      minutes: {
        UsageCategoryId.social: social,
        UsageCategoryId.work: work,
        UsageCategoryId.video: video,
        UsageCategoryId.other: total - social - work - video,
      },
    );
  }

  final current = [
    for (var i = 0; i < currentTotals.length; i++)
      makeDay(start.add(Duration(days: i)), currentTotals[i], today: i == 6),
  ];
  final previousStart = start.subtract(const Duration(days: 7));
  final previous = [
    for (var i = 0; i < previousTotals.length; i++)
      makeDay(previousStart.add(Duration(days: i)), previousTotals[i]),
  ];

  return UsageOverview(
    dailyTargetMinutes: 360,
    currentWeek: current,
    previousWeek: previous,
    appsToday: const [
      AppUsage(
        name: 'Instagram',
        category: UsageCategoryId.social,
        minutes: 58,
        icon: Icons.camera_alt_rounded,
        color: Color(0xFFE786A5),
      ),
      AppUsage(
        name: 'YouTube',
        category: UsageCategoryId.video,
        minutes: 46,
        icon: Icons.smart_display_rounded,
        color: Color(0xFFFF7878),
      ),
      AppUsage(
        name: 'Telegram',
        category: UsageCategoryId.social,
        minutes: 39,
        icon: Icons.send_rounded,
        color: Color(0xFF73B9F4),
      ),
      AppUsage(
        name: 'Notion',
        category: UsageCategoryId.work,
        minutes: 34,
        icon: Icons.note_alt_rounded,
        color: Color(0xFFE8E8E8),
      ),
      AppUsage(
        name: 'Safari',
        category: UsageCategoryId.other,
        minutes: 28,
        icon: Icons.travel_explore_rounded,
        color: Color(0xFF8EC8FF),
      ),
    ],
  );
}

String get formattedDate {
  const weekdays = [
    'понедельник',
    'вторник',
    'среда',
    'четверг',
    'пятница',
    'суббота',
    'воскресенье',
  ];
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  final date = DateTime.now();
  return '${weekdays[date.weekday - 1].toUpperCase()}, ${date.day} ${months[date.month - 1]}';
}

String weekdayShort(int weekday) =>
    const ['ПН', 'ВТ', 'СР', 'ЧТ', 'ПТ', 'СБ', 'ВС'][weekday - 1];
