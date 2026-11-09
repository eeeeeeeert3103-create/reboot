import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/services/streak_store.dart';

StreakDay _day(String key, int minutes) =>
    StreakDay(day: LocalDay.tryParse(key)!, minutes: minutes, goalMinutes: 360);

void main() {
  late Directory directory;
  const today = LocalDay(2026, 11, 5);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reboot-streak-test-');
  });
  tearDown(() => directory.delete(recursive: true));

  File streakFile() =>
      File('${directory.path}${Platform.pathSeparator}${StreakStore.fileName}');

  test('records only finished days and survives reopening', () async {
    final store = StreakStore(directory: directory);
    await store.load();
    final added = await store.recordCompletedDays([
      _day('2026-11-03', 100),
      _day('2026-11-04', 200),
      _day('2026-11-05', 50),
      _day('2026-11-06', 50),
    ], today: today);

    expect(added, 2);
    final reopened = StreakStore(directory: directory);
    await reopened.load();
    expect(reopened.days.map((d) => d.day.key), ['2026-11-03', '2026-11-04']);
  });

  test('a recorded day is frozen and never counted twice', () async {
    final store = StreakStore(directory: directory);
    await store.load();
    await store.recordCompletedDays([_day('2026-11-04', 200)], today: today);

    // Restart, repeated sync and changed values for the same local date.
    final reopened = StreakStore(directory: directory);
    await reopened.load();
    final added = await reopened.recordCompletedDays([
      _day('2026-11-04', 900),
      _day('2026-11-04', 10),
    ], today: today.addDays(1));

    expect(added, 0);
    expect(reopened.days, hasLength(1));
    expect(reopened.days.single.minutes, 200);
  });

  test(
    'unreadable ledger disables writing instead of overwriting it',
    () async {
      await streakFile().writeAsString('{"version": 99}');
      final store = StreakStore(directory: directory);
      await store.load();

      expect(store.isAvailable, isFalse);
      expect(store.issue, isNotNull);
      expect(
        await store.recordCompletedDays([_day('2026-11-04', 1)], today: today),
        0,
      );
      expect(await streakFile().readAsString(), '{"version": 99}');
    },
  );

  test('clear removes the ledger file', () async {
    final store = StreakStore(directory: directory);
    await store.load();
    await store.recordCompletedDays([_day('2026-11-04', 1)], today: today);
    expect(await streakFile().exists(), isTrue);

    await store.clear();
    expect(await streakFile().exists(), isFalse);
    expect(store.days, isEmpty);
  });

  test('unavailable store never writes', () async {
    final store = StreakStore.unavailable();
    await store.load();
    expect(
      await store.recordCompletedDays([_day('2026-11-04', 1)], today: today),
      0,
    );
    await store.clear();
    expect(store.days, isEmpty);
  });
}
