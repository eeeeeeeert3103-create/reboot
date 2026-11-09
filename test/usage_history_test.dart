import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/collector_models.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/models/usage_history.dart';
import 'package:reboot_app/models/usage_report.dart';
import 'package:reboot_app/services/usage_history_store.dart';

DateTime local(int d, int h, [int m = 0, int s = 0]) =>
    DateTime(2026, 11, d, h, m, s);

UsageEvent ended(String app, DateTime at, int seconds) => UsageEvent(
  type: UsageEventType.foregroundEnded,
  timestamp: at,
  appIdentifier: app,
  displayName: app,
  durationSeconds: seconds,
);

UsageEvent event(UsageEventType type, DateTime at, [String? app]) =>
    UsageEvent(type: type, timestamp: at, appIdentifier: app, displayName: app);

CollectorSnapshot snapshot(List<UsageEvent> events, DateTime captured) =>
    CollectorSnapshot(
      platform: CollectorPlatform.macOS,
      capturedAt: captured,
      events: events,
    );

AppSession session(String app, DateTime start, DateTime end) =>
    AppSession(appId: app, appName: app, start: start, end: end);

void main() {
  group('EventIngestor', () {
    test('turns foreground segments, launches and periods into records', () {
      final ingestor = EventIngestor();
      final batch = ingestor.ingest(
        snapshot([
          event(UsageEventType.appLaunched, local(5, 9), 'com.a'),
          ended('com.a', local(5, 9, 10), 600),
          event(UsageEventType.sessionLocked, local(5, 9, 10)),
          event(UsageEventType.sessionLocked, local(5, 9, 12)),
          event(UsageEventType.sessionUnlocked, local(5, 9, 20)),
          ended('com.b', local(5, 9, 21), 0),
        ], local(5, 9, 30)),
      );
      expect(batch.sessions.single.duration, const Duration(minutes: 10));
      expect(batch.launches.single.appId, 'com.a');
      final lock = batch.intervals.single;
      expect(lock.kind, IntervalKind.locked);
      expect(lock.start, local(5, 9, 10).toUtc(), reason: 'repeat ignored');
      expect(lock.duration, const Duration(minutes: 10));
    });

    test('an idle period spanning two drains is closed once', () {
      final ingestor = EventIngestor();
      final first = ingestor.ingest(
        snapshot([
          event(UsageEventType.idleStarted, local(5, 10)),
        ], local(5, 10, 3)),
      );
      expect(first.intervals, isEmpty);
      expect(first.inactiveWindows.single.$1, local(5, 10).toUtc());
      final second = ingestor.ingest(
        snapshot([
          event(UsageEventType.idleEnded, local(5, 10, 20)),
        ], local(5, 10, 21)),
      );
      expect(second.intervals.single.duration, const Duration(minutes: 20));
      expect(ingestor.close(local(5, 11)).intervals, isEmpty);
    });
  });

  group('HistoryIndex', () {
    test('splits sessions at local midnight', () {
      final index = HistoryIndex(
        sessions: [session('a', local(4, 23, 30), local(5, 0, 45))],
        launches: const [],
        intervals: const [],
      );
      expect(index.day(const LocalDay(2026, 11, 4)).activeSeconds, 30 * 60);
      expect(index.day(const LocalDay(2026, 11, 5)).activeSeconds, 45 * 60);
    });

    test('a day keeps its real length across daylight-saving changes', () {
      final start = DateTime(2026, 3, 29);
      final end = DateTime(2026, 3, 30);
      final split = splitByLocalDay(start, end);
      expect(split.keys.single, const LocalDay(2026, 3, 29));
      // 23 h in zones that switch to summer time that night, 24 h elsewhere.
      expect(split.values.single, end.difference(start).inSeconds);
    });

    test('overlapping sessions are never counted twice in day totals', () {
      final index = HistoryIndex(
        sessions: [
          session('a', local(5, 10), local(5, 11)),
          session('b', local(5, 10, 30), local(5, 11, 30)),
          session('a', local(5, 10, 15), local(5, 10, 45)),
        ],
        launches: const [],
        intervals: const [],
      );
      expect(index.day(const LocalDay(2026, 11, 5)).activeSeconds, 90 * 60);
      final apps = index.apps(
        const LocalDay(2026, 11, 5),
        const LocalDay(2026, 11, 5),
      );
      expect(apps.first.appId, 'a');
      expect(apps.first.activeSeconds, 60 * 60);
      expect(apps.first.sessions, 2);
    });

    test('daily launches, unlocks, idle and coverage', () {
      final index = HistoryIndex(
        sessions: const [],
        launches: [
          AppLaunch(appId: 'a', appName: 'A', at: local(5, 9)),
          AppLaunch(appId: 'a', appName: 'A', at: local(5, 12)),
        ],
        intervals: [
          TimeInterval(
            kind: IntervalKind.locked,
            start: local(5, 12),
            end: local(5, 13),
          ),
          TimeInterval(
            kind: IntervalKind.idle,
            start: local(5, 14),
            end: local(5, 14, 5),
          ),
          TimeInterval(
            kind: IntervalKind.coverage,
            start: local(5, 8),
            end: local(5, 20),
          ),
        ],
      );
      final day = index.day(const LocalDay(2026, 11, 5));
      expect(day.launches, 2);
      expect(day.unlocks, 1);
      expect(day.idleSeconds, 300);
      expect(day.coverageSeconds, 12 * 3600);
      expect(index.day(const LocalDay(2026, 11, 6)).hasData, isFalse);
    });

    test('streak only counts finished days with enough coverage', () {
      final index = HistoryIndex(
        sessions: [
          session('a', local(3, 10), local(3, 12)),
          session('a', local(4, 10), local(4, 11)),
        ],
        launches: const [],
        intervals: [
          TimeInterval(
            kind: IntervalKind.coverage,
            start: local(3, 0),
            end: local(4, 0),
          ),
          TimeInterval(
            kind: IntervalKind.coverage,
            start: local(4, 9),
            end: local(4, 12),
          ),
          TimeInterval(
            kind: IntervalKind.coverage,
            start: local(5, 0),
            end: local(5, 23),
          ),
        ],
      );
      final days = index.completedStreakDays(
        today: const LocalDay(2026, 11, 5),
        goalMinutes: 180,
      );
      expect(days.map((d) => d.day.key), ['2026-11-03']);
      expect(days.single.minutes, 120);
    });

    test('report averages only over days with data', () {
      final index = HistoryIndex(
        sessions: [session('a', local(5, 10), local(5, 12))],
        launches: const [],
        intervals: [
          TimeInterval(
            kind: IntervalKind.coverage,
            start: local(5, 9),
            end: local(5, 13),
          ),
        ],
      );
      final report = buildRealReport(
        index: index,
        today: const LocalDay(2026, 11, 5),
        goalMinutes: 60,
      );
      expect(report.days, hasLength(7));
      expect(report.daysWithData, hasLength(1));
      expect(report.averageActiveSeconds, 7200);
      expect(report.daysWithinGoal, 0);
      expect(report.changeFraction, isNull);
      final month = buildRealReport(
        index: index,
        today: const LocalDay(2026, 11, 5),
        goalMinutes: 60,
        periodDays: 30,
      );
      expect(month.days, hasLength(30));
      expect(month.periodActiveSeconds, 7200);
    });

    test('empty history gives an empty report, not zeros as data', () {
      final report = buildRealReport(
        index: HistoryIndex(
          sessions: const [],
          launches: const [],
          intervals: const [],
        ),
        today: const LocalDay(2026, 11, 5),
        goalMinutes: 60,
      );
      expect(report.hasAnyData, isFalse);
      expect(report.daysWithData, isEmpty);
      expect(report.averageActiveSeconds, 0);
    });
  });

  test('union merges touching and nested intervals', () {
    final merged = unionOf([
      (local(5, 10), local(5, 11)),
      (local(5, 11), local(5, 12)),
      (local(5, 10, 30), local(5, 10, 40)),
      (local(5, 14), local(5, 14)),
    ]);
    expect(merged, [(local(5, 10), local(5, 12))]);
  });

  group('UsageHistoryStore', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('reboot-history-test-');
    });
    tearDown(() => directory.delete(recursive: true));

    UsageHistoryStore store() =>
        UsageHistoryStore(directory: directory, clock: () => local(5, 12));

    test('merges checkpoint pieces and ignores repeated batches', () async {
      final s = store();
      await s.load();
      final batch = HistoryBatch(
        sessions: [session('a', local(5, 10), local(5, 10, 0, 30))],
      );
      await s.add(batch);
      await s.add(batch);
      await s.add(
        HistoryBatch(
          sessions: [session('a', local(5, 10, 0, 30), local(5, 10, 1))],
        ),
      );
      expect(s.sessions, hasLength(1));
      expect(s.sessions.single.duration, const Duration(minutes: 1));

      final reopened = store();
      await reopened.load();
      expect(reopened.sessions.single.end, local(5, 10, 1).toUtc());
    });

    test('idle windows remove already stored active time', () async {
      final s = store();
      await s.load();
      await s.add(
        HistoryBatch(sessions: [session('a', local(5, 10), local(5, 10, 10))]),
      );
      await s.add(
        HistoryBatch(
          inactiveWindows: [
            (local(5, 10, 8).toUtc(), local(5, 10, 30).toUtc()),
          ],
        ),
      );
      expect(s.sessions.single.end, local(5, 10, 8).toUtc());
    });

    test('coverage is one interval per run, extended each poll', () async {
      final s = store();
      await s.load();
      await s.extendCoverage(local(5, 9), local(5, 9, 1));
      await s.extendCoverage(local(5, 9), local(5, 11));
      final coverage = s.intervals.where(
        (i) => i.kind == IntervalKind.coverage,
      );
      expect(coverage.single.duration, const Duration(hours: 2));
    });

    test('records older than the retention period are deleted', () async {
      final folder = Directory('${directory.path}/usage-history')..createSync();
      File('${folder.path}/2026-07-01.json').writeAsStringSync(
        '{"version":1,"sessions":[],"launches":[],"intervals":[]}',
      );
      final s = store();
      await s.load();
      expect(File('${folder.path}/2026-07-01.json').existsSync(), isFalse);
    });

    test('unreadable files pause writing instead of overwriting', () async {
      final folder = Directory('${directory.path}/usage-history')..createSync();
      final file = File('${folder.path}/2026-11-05.json')
        ..writeAsStringSync('{');
      final s = store();
      await s.load();
      expect(s.isAvailable, isFalse);
      await s.add(
        HistoryBatch(sessions: [session('a', local(5, 10), local(5, 11))]),
      );
      expect(file.readAsStringSync(), '{');
    });

    test('clear removes the whole folder', () async {
      final s = store();
      await s.load();
      await s.add(
        HistoryBatch(sessions: [session('a', local(5, 10), local(5, 11))]),
      );
      await s.clear();
      expect(
        Directory('${directory.path}/usage-history').existsSync(),
        isFalse,
      );
      expect(s.isEmpty, isTrue);
    });
  });
}
