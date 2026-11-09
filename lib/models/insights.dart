import 'streak.dart';
import 'usage_data.dart';
import 'usage_report.dart';

/// Plain arithmetic over stored data. Every rule states how much data it
/// needs; with less data the rule stays silent instead of guessing.
/// No advice, no diagnoses, no judgement of the user.
class Insight {
  const Insight({
    required this.title,
    required this.detail,
    required this.basis,
  });
  final String title;
  final String detail;

  /// What the statement is based on, shown under it.
  final String basis;
}

const _weekdayNames = [
  'понедельник',
  'вторник',
  'среда',
  'четверг',
  'пятница',
  'суббота',
  'воскресенье',
];

String weekdayName(int weekday) => _weekdayNames[weekday - 1];

String hourRange(int fromHour, int toHour) =>
    '${fromHour.toString().padLeft(2, '0')}:00–${(toHour % 24).toString().padLeft(2, '0')}:00';

/// Minimum days with data before a rule may speak.
abstract final class InsightThresholds {
  static const weekComparison = 4;
  static const average = 3;
  static const topApp = 3;
  static const dayOfWeek = 10;
  static const timeOfDay = 5;
  static const goal = 5;
}

List<Insight> buildInsights({
  required UsageReport week,
  ActivityHeatmap? heatmap,
  int heatmapDays = 0,
}) {
  final insights = <Insight>[];
  final withData = week.daysWithData;
  final previousWithData = week.previousDays.where((d) => d.hasData).length;

  final change = week.changeFraction;
  if (change != null &&
      withData.length >= InsightThresholds.weekComparison &&
      previousWithData >= InsightThresholds.weekComparison) {
    final percent = formatPercent(change.abs());
    insights.add(
      Insight(
        title: change.abs() < .05
            ? 'Экранное время почти не изменилось'
            : change < 0
            ? 'Экранное время уменьшилось на $percent'
            : 'Экранное время выросло на $percent',
        detail:
            '${formatDuration(week.periodActiveSeconds)} против ${formatDuration(week.previousActiveSeconds)} в предыдущие ${week.periodDays} дн.',
        basis: 'дней с данными: ${withData.length} и $previousWithData',
      ),
    );
  }

  if (withData.length >= InsightThresholds.average) {
    insights.add(
      Insight(
        title:
            'Среднее экранное время — ${formatDuration(week.averageActiveSeconds)} в день',
        detail: 'Считается только по дням, когда шёл сбор.',
        basis: 'дней с данными: ${withData.length} из ${week.periodDays}',
      ),
    );
  }

  final apps = week.appsPeriod ?? const <AppTotal>[];
  if (apps.isNotEmpty &&
      withData.length >= InsightThresholds.topApp &&
      week.periodActiveSeconds > 0) {
    final top = apps.first;
    insights.add(
      Insight(
        title: 'Больше всего времени — в ${top.name}',
        detail:
            '${formatDuration(top.activeSeconds)}, ${formatPercent(top.activeSeconds / week.periodActiveSeconds)} от активного времени за период.',
        basis: 'дней с данными: ${withData.length}',
      ),
    );
  }

  if (withData.length >= InsightThresholds.goal) {
    insights.add(
      Insight(
        title:
            'Цель выполнена в ${week.daysWithinGoal} из ${withData.length} дн.',
        detail: 'Дневная цель — ${formatMinutes(week.goalMinutes)}.',
        basis: 'только дни с данными',
      ),
    );
  }

  final map = heatmap;
  if (map != null && !map.isEmpty) {
    if (heatmapDays >= InsightThresholds.dayOfWeek) {
      var best = -1;
      var bestAverage = 0;
      for (var w = 0; w < 7; w++) {
        if (map.coveredDays[w] < 2) continue;
        final average = map.byWeekday[w] ~/ map.coveredDays[w];
        if (average > bestAverage) {
          bestAverage = average;
          best = w;
        }
      }
      if (best >= 0) {
        insights.add(
          Insight(
            title: 'Самый активный день — ${weekdayName(best + 1)}',
            detail:
                'В среднем ${formatDuration(bestAverage)} в этот день недели.',
            basis:
                'дней с данными: $heatmapDays, из них «${weekdayName(best + 1)}» — ${map.coveredDays[best]}',
          ),
        );
      }
    }
    if (heatmapDays >= InsightThresholds.timeOfDay) {
      final hours = map.byHour;
      int sum(int from, int to) =>
          [for (var h = from; h < to; h++) hours[h]].fold(0, (a, b) => a + b);
      final morning = sum(6, 12), evening = sum(18, 24);
      if (morning > 0 || evening > 0) {
        if (evening > morning * 1.2) {
          insights.add(
            Insight(
              title: 'Вечерняя активность выше, чем утренняя',
              detail:
                  '18:00–24:00 — ${formatDuration(evening)}, 06:00–12:00 — ${formatDuration(morning)}.',
              basis: 'дней с данными: $heatmapDays',
            ),
          );
        } else if (morning > evening * 1.2) {
          insights.add(
            Insight(
              title: 'Утренняя активность выше, чем вечерняя',
              detail:
                  '06:00–12:00 — ${formatDuration(morning)}, 18:00–24:00 — ${formatDuration(evening)}.',
              basis: 'дней с данными: $heatmapDays',
            ),
          );
        }
      }
      var peakStart = 0;
      var peak = -1;
      for (var h = 0; h <= 21; h++) {
        final window = sum(h, h + 3);
        if (window > peak) {
          peak = window;
          peakStart = h;
        }
      }
      if (peak > 0) {
        insights.add(
          Insight(
            title:
                'Наиболее активный период — ${hourRange(peakStart, peakStart + 3)}',
            detail:
                '${formatPercent(peak / map.totalSeconds)} всей активности приходится на эти три часа.',
            basis: 'дней с данными: $heatmapDays',
          ),
        );
      }
    }
  }
  return insights;
}

/// Monday of the week that contains [day].
LocalDay weekStart(LocalDay day) => day.addDays(-(day.weekday - 1));

class WeeklyReport {
  WeeklyReport({
    required this.mode,
    required this.start,
    required this.usage,
    required this.heatmap,
    required this.streak,
    required this.focusSeconds,
    required this.focusSessions,
  });

  final UsageDataMode mode;
  final LocalDay start;
  final UsageReport usage;
  final ActivityHeatmap? heatmap;
  final StreakSummary streak;
  final int? focusSeconds;
  final int? focusSessions;

  LocalDay get end => start.addDays(6);
  int get daysWithData => usage.daysWithData.length;
  bool get hasEnoughData => daysWithData >= 3;
  List<AppTotal> get topApps =>
      (usage.appsPeriod ?? usage.appsToday).take(5).toList();

  DayUsage? get mostActiveDay {
    final days = usage.daysWithData.where((d) => d.activeSeconds > 0);
    if (days.isEmpty) return null;
    return days.reduce((a, b) => b.activeSeconds > a.activeSeconds ? b : a);
  }

  int? get mostActiveHour {
    final map = heatmap;
    if (map == null || map.isEmpty) return null;
    final hours = map.byHour;
    var best = 0;
    for (var h = 1; h < 24; h++) {
      if (hours[h] > hours[best]) best = h;
    }
    return best;
  }

  Map<String, Object?> toMap() => {
    'type': 'REBOOT weekly report',
    'mode': mode.name,
    'week': {'from': start.key, 'to': end.key},
    'daysWithData': daysWithData,
    'totalActiveSeconds': usage.periodActiveSeconds,
    'previousWeekActiveSeconds': usage.previousActiveSeconds,
    'changeFraction': usage.changeFraction,
    'averageActiveSeconds': usage.averageActiveSeconds,
    'launches': usage.periodLaunches,
    'goalMinutes': usage.goalMinutes,
    'daysWithinGoal': usage.daysWithinGoal,
    'mostActiveDay': mostActiveDay?.day.key,
    'mostActiveHour': mostActiveHour,
    'topApps': [
      for (final app in topApps)
        {
          'app': app.appId,
          'name': app.name,
          'activeSeconds': app.activeSeconds,
          'launches': app.launches,
        },
    ],
    'streak': {'current': streak.current, 'best': streak.best},
    'focus': {'seconds': focusSeconds, 'sessions': focusSessions},
    'days': [
      for (final d in usage.days)
        {
          'date': d.day.key,
          'hasData': d.hasData,
          'activeSeconds': d.activeSeconds,
          'idleSeconds': d.idleSeconds,
        },
    ],
  };
}
