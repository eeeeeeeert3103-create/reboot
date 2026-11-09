import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/usage_data.dart';

void main() {
  group('demo usage arithmetic consistency', () {
    test('today total, categories and daily goal derive from one dataset', () {
      final usage = demoUsage;
      expect(usage.todayMinutes, 342);
      expect(usage.todayByCategory.values.reduce((a, b) => a + b), 342);
      expect(usage.dailyTargetMinutes, 360);
      expect(usage.todayGoalProgress, closeTo(.95, .0001));
      expect(usage.minutesToGoal, 18);
    });

    test('weekly charts, average and comparison match the underlying days', () {
      final usage = demoUsage;
      expect(usage.currentWeek, hasLength(7));
      expect(usage.previousWeek, hasLength(7));
      expect(usage.currentWeekMinutes, 2490);
      expect(usage.previousWeekMinutes, 2790);
      expect(usage.averagePerDayMinutes, 356);
      expect(usage.weekChangeFraction, closeTo(-300 / 2790, .000001));
      expect(formatPercent(usage.weekChangeFraction!.abs()), '11%');
    });

    test('goal days and weekly category totals reconcile with chart total', () {
      final usage = demoUsage;
      expect(usage.daysAtOrBelowTarget, 4);
      expect(
        usage.currentWeekByCategory.values.reduce((a, b) => a + b),
        usage.currentWeekMinutes,
      );
      for (final day in [...usage.currentWeek, ...usage.previousWeek]) {
        expect(day.totalMinutes, greaterThan(0));
      }
    });

    test('daily records reject category totals that do not reconcile', () {
      expect(
        () => DailyUsage(
          date: DateTime.utc(2026, 1, 1),
          totalMinutes: 61,
          minutes: const {
            UsageCategoryId.social: 60,
            UsageCategoryId.work: 0,
            UsageCategoryId.video: 0,
            UsageCategoryId.other: 0,
          },
        ),
        throwsArgumentError,
      );
    });

    test(
      'weekday labels follow date weekday instead of fixed Monday start',
      () {
        expect(weekdayShort(DateTime.utc(2026, 11, 1).weekday), 'ВС');
        expect(weekdayShort(DateTime.utc(2026, 11, 2).weekday), 'ПН');
      },
    );
  });
}
