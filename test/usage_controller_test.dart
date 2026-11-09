import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/services/consent_store.dart';
import 'package:reboot_app/services/streak_store.dart';
import 'package:reboot_app/services/usage_controller.dart';
import 'package:reboot_app/services/usage_history_store.dart';

import 'support/fakes.dart';

void main() {
  late Directory directory;
  late DateTime now;
  late FakeCollector collector;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reboot-controller-');
    now = DateTime(2026, 11, 4, 8);
    collector = FakeCollector(clock: () => now);
  });
  tearDown(() => directory.delete(recursive: true));

  UsageController controller(ConsentStore consent) => UsageController(
    collector: collector,
    history: UsageHistoryStore(directory: directory, clock: () => now),
    streak: StreakStore(directory: directory),
    consent: consent,
    clock: () => now,
    pollInterval: const Duration(days: 1),
  );

  test('without consent nothing starts and the mode is DEMO', () async {
    final c = controller(ConsentStore(directory: directory));
    await c.load();
    await c.startCollection();
    expect(collector.startCalls, 0);
    expect(c.mode, UsageDataMode.demo);
    expect(c.lastError, contains('согласия'));
    c.dispose();
  });

  test('consent alone is not REAL until the user picks REAL', () async {
    final c = controller(ConsentStore(directory: directory));
    await c.load();
    await c.setConsent(true);
    expect(collector.startCalls, 0);
    expect(c.mode, UsageDataMode.demo);
    await c.setPreferRealData(true);
    expect(collector.startCalls, 1);
    expect(c.mode, UsageDataMode.real);
    c.dispose();
  });

  test(
    'REAL data flows into reports and finished days into the streak',
    () async {
      final c = controller(
        ConsentStore.inMemory(
          const PrivacyChoices(
            onboardingCompleted: true,
            collectionConsent: true,
            preferRealData: true,
          ),
        ),
      );
      c.goalMinutes = 120;
      await c.load();
      expect(collector.collecting, isTrue);

      // Day 1: 90 minutes of use, collector alive the whole day.
      collector.foreground(
        'com.editor',
        DateTime(2026, 11, 4, 10, 30),
        90 * 60,
      );
      now = DateTime(2026, 11, 4, 23, 59);
      await c.sync();
      var report = c.report(today: const LocalDay(2026, 11, 4));
      expect(report.mode, UsageDataMode.real);
      expect(report.todayUsage.activeSeconds, 90 * 60);
      expect(report.appsToday.single.appId, 'com.editor');
      expect(c.streakDays, isEmpty, reason: 'today is never counted early');

      // After midnight the finished day qualifies (coverage ≥ 12 h).
      now = DateTime(2026, 11, 5, 0, 1);
      await c.sync();
      expect(c.streakDays.single.day, const LocalDay(2026, 11, 4));
      expect(c.streakDays.single.goalMet, isTrue);
      final summary = c.streakSummary(today: const LocalDay(2026, 11, 5));
      expect(summary.current, 1);

      // Repeated syncs never record the same day twice.
      await c.sync();
      expect(c.streakDays, hasLength(1));

      // Revoking consent stops collection; the mode falls back to DEMO.
      await c.setConsent(false);
      expect(collector.collecting, isFalse);
      expect(c.mode, UsageDataMode.demo);
      report = c.report(today: const LocalDay(2026, 11, 5));
      expect(report.mode, UsageDataMode.demo);
      c.dispose();
    },
  );

  test('a day with short coverage is not judged', () async {
    final c = controller(
      ConsentStore.inMemory(
        const PrivacyChoices(collectionConsent: true, preferRealData: true),
      ),
    );
    now = DateTime(2026, 11, 4, 20);
    await c.load();
    collector.foreground('com.a', DateTime(2026, 11, 4, 20, 30), 600);
    now = DateTime(2026, 11, 4, 21);
    await c.sync();
    now = DateTime(2026, 11, 5, 9);
    await c.sync();
    // Collected only 20:00–24:00 on Nov 4: 4 h < 12 h, so not judged.
    expect(c.streakDays, isEmpty);
    c.dispose();
  });

  test('unavailable collector keeps DEMO even with consent', () async {
    collector.available = false;
    final c = controller(
      ConsentStore.inMemory(
        const PrivacyChoices(collectionConsent: true, preferRealData: true),
      ),
    );
    await c.load();
    expect(c.mode, UsageDataMode.demo);
    expect(collector.startCalls, 0);
    c.dispose();
  });

  test('export contains choices, history and streak; clearing works', () async {
    final c = controller(
      ConsentStore.inMemory(
        const PrivacyChoices(collectionConsent: true, preferRealData: true),
      ),
    );
    await c.load();
    collector.foreground('com.a', DateTime(2026, 11, 4, 8, 10), 300);
    now = DateTime(2026, 11, 4, 8, 20);
    await c.sync();
    final export = c.exportData();
    expect(
      export.keys,
      containsAll(['privacyChoices', 'usageHistory', 'streakHistory']),
    );
    expect((export['usageHistory']! as Map)['sessions'], hasLength(1));
    await c.clearUsageHistory();
    expect(c.historyIsEmpty, isTrue);
    expect(collector.collecting, isFalse);
    c.dispose();
  });
}
