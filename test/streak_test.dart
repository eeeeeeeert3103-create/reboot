import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/models/usage_data.dart';

StreakDay _day(String key, int minutes, {int goal = 360}) => StreakDay(
  day: LocalDay.tryParse(key)!,
  minutes: minutes,
  goalMinutes: goal,
);

void main() {
  group('LocalDay', () {
    test('uses zero-padded local date keys and rejects invalid dates', () {
      expect(const LocalDay(2026, 3, 7).key, '2026-03-07');
      expect(LocalDay.tryParse('2026-02-30'), isNull);
      expect(LocalDay.tryParse('2026-2-3'), isNull);
      expect(LocalDay.tryParse(20260203), isNull);
      expect(LocalDay.tryParse('2028-02-29'), const LocalDay(2028, 2, 29));
    });

    test('calendar arithmetic crosses months, years and DST dates', () {
      expect(
        const LocalDay(2026, 12, 31).addDays(1),
        const LocalDay(2027, 1, 1),
      );
      expect(
        const LocalDay(2026, 3, 1).addDays(-1),
        const LocalDay(2026, 2, 28),
      );
      // Last Sunday of March / October: daylight-saving switches in Europe.
      expect(
        const LocalDay(2026, 3, 29).addDays(1),
        const LocalDay(2026, 3, 30),
      );
      expect(
        const LocalDay(2026, 10, 25).addDays(1),
        const LocalDay(2026, 10, 26),
      );
      expect(
        const LocalDay(2026, 10, 24).daysUntil(const LocalDay(2026, 10, 26)),
        2,
      );
    });

    test('is taken from the local wall clock of a timestamp', () {
      final local = DateTime(2026, 11, 5, 23, 59);
      expect(LocalDay.fromDateTime(local), const LocalDay(2026, 11, 5));
      expect(LocalDay.fromDateTime(local.toUtc()), const LocalDay(2026, 11, 5));
    });
  });

  group('StreakCalculator', () {
    const today = LocalDay(2026, 11, 5);

    test('counts finished days within the goal, ending yesterday', () {
      final summary = StreakCalculator.summarize(
        days: [
          _day('2026-11-01', 400),
          _day('2026-11-02', 300),
          _day('2026-11-03', 360),
          _day('2026-11-04', 200),
        ],
        today: today,
        goalMinutes: 360,
        todayMinutes: 90,
      );
      expect(summary.current, 3);
      expect(summary.best, 3);
      expect(summary.todayProgress, closeTo(.25, 1e-9));
    });

    test('today is never counted, even when already within the goal', () {
      final summary = StreakCalculator.summarize(
        days: [_day('2026-11-04', 100), _day('2026-11-05', 10)],
        today: today,
        goalMinutes: 360,
      );
      expect(summary.current, 1);
      expect(summary.history.map((d) => d.day.key), ['2026-11-04']);
    });

    test('a missing or over-goal yesterday restarts the current run', () {
      final gap = StreakCalculator.summarize(
        days: [_day('2026-11-02', 100), _day('2026-11-03', 100)],
        today: today,
        goalMinutes: 360,
      );
      expect(gap.current, 0);
      expect(gap.best, 2);

      final over = StreakCalculator.summarize(
        days: [_day('2026-11-03', 100), _day('2026-11-04', 500)],
        today: today,
        goalMinutes: 360,
      );
      expect(over.current, 0);
      expect(over.best, 1);
    });

    test('best run requires consecutive calendar days', () {
      final summary = StreakCalculator.summarize(
        days: [
          _day('2026-10-01', 100),
          _day('2026-10-02', 100),
          _day('2026-10-04', 100),
          _day('2026-10-05', 100),
          _day('2026-10-06', 100),
          _day('2026-10-07', 900),
        ],
        today: today,
        goalMinutes: 360,
      );
      expect(summary.best, 3);
    });

    test('a duplicated day is counted once, the first record wins', () {
      final summary = StreakCalculator.summarize(
        days: [_day('2026-11-04', 100), _day('2026-11-04', 900)],
        today: today,
        goalMinutes: 360,
      );
      expect(summary.history, hasLength(1));
      expect(summary.current, 1);
    });

    test('days after today (clock or time zone moved back) are ignored', () {
      final summary = StreakCalculator.summarize(
        days: [_day('2026-11-04', 100), _day('2026-11-06', 100)],
        today: today,
        goalMinutes: 360,
      );
      expect(summary.history.map((d) => d.day.key), ['2026-11-04']);
      expect(summary.current, 1);
    });

    test('each day keeps the goal that applied to it', () {
      final summary = StreakCalculator.summarize(
        days: [_day('2026-11-04', 400, goal: 420)],
        today: today,
        goalMinutes: 300,
      );
      expect(summary.current, 1);
    });
  });

  test('demo preview is built from fixtures and excludes today', () {
    final usage = demoUsage.withTarget(360);
    final today = LocalDay.fromDateTime(usage.today.date);
    final summary = demoStreakPreview(usage, today: today);
    expect(summary.history, hasLength(13));
    expect(summary.dayFor(today), isNull);
    expect(summary.todayMinutes, usage.todayMinutes);
  });

  test('streak day map rejects malformed records', () {
    expect(
      () => StreakDay.fromMap({
        'date': '2026-11-04',
        'minutes': -1,
        'goalMinutes': 360,
      }),
      throwsFormatException,
    );
    expect(
      () => StreakDay.fromMap({
        'date': 'yesterday',
        'minutes': 1,
        'goalMinutes': 360,
      }),
      throwsFormatException,
    );
    final restored = StreakDay.fromMap(_day('2026-11-04', 12).toMap());
    expect(restored.day.key, '2026-11-04');
    expect(restored.minutes, 12);
  });
}
