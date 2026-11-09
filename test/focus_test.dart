import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/focus_session.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/models/usage_history.dart';
import 'package:reboot_app/models/usage_report.dart';
import 'package:reboot_app/screens/focus_screen.dart';
import 'package:reboot_app/services/focus_store.dart';
import 'package:reboot_app/theme/reboot_themes.dart';

class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

FocusSession _session(
  String id,
  DateTime start, {
  int minutes = 25,
  FocusStatus status = FocusStatus.completed,
}) => FocusSession(
  id: id,
  plannedSeconds: 25 * 60,
  startedAt: start,
  endedAt: start.add(Duration(minutes: minutes)),
  pausedSeconds: 0,
  status: status,
);

void main() {
  group('FocusTimer', () {
    test('uses wall-clock time when the app is minimised', () {
      final clock = _Clock(DateTime(2026, 11, 5, 10));
      final timer = FocusTimer(clock: clock.call)..start(25 * 60);
      expect(timer.remainingSeconds, 25 * 60);
      // No ticks at all: the window was hidden and the clock jumped.
      clock.advance(const Duration(minutes: 10));
      expect(timer.state, FocusTimerState.running);
      expect(timer.elapsedSeconds, 600);
      expect(timer.remainingSeconds, 15 * 60);
    });

    test('pause and resume exclude the paused time', () {
      final clock = _Clock(DateTime(2026, 11, 5, 10));
      final timer = FocusTimer(clock: clock.call)..start(25 * 60);
      clock.advance(const Duration(minutes: 5));
      timer.pause();
      expect(timer.state, FocusTimerState.paused);
      clock.advance(const Duration(minutes: 30));
      expect(timer.remainingSeconds, 20 * 60, reason: 'frozen while paused');
      expect(timer.pausedSeconds, 30 * 60);
      timer.resume();
      clock.advance(const Duration(minutes: 5));
      expect(timer.remainingSeconds, 15 * 60);
      final session = timer.finish()!;
      expect(session.status, FocusStatus.stopped);
      expect(session.pausedSeconds, 30 * 60);
      expect(session.focusedSeconds, 10 * 60);
      expect(session.spanSeconds, 40 * 60);
    });

    test('completes automatically at the exact planned moment', () {
      final start = DateTime(2026, 11, 5, 10);
      final clock = _Clock(start);
      final timer = FocusTimer(clock: clock.call)..start(25 * 60);
      clock.advance(const Duration(minutes: 3));
      timer.pause();
      clock.advance(const Duration(minutes: 2));
      timer.resume();
      // Computer slept well past the end.
      clock.advance(const Duration(hours: 2));
      expect(timer.state, FocusTimerState.finished);
      expect(timer.remainingSeconds, 0);
      final session = timer.result!;
      expect(session.status, FocusStatus.completed);
      expect(session.focusedSeconds, 25 * 60);
      expect(session.pausedSeconds, 120);
      expect(session.endedAt, start.toUtc().add(const Duration(minutes: 27)));
      // Finishing afterwards does not turn it into "stopped".
      expect(timer.finish()!.status, FocusStatus.completed);
    });

    test('a paused timer never completes on its own', () {
      final clock = _Clock(DateTime(2026, 11, 5, 10));
      final timer = FocusTimer(clock: clock.call)..start(5 * 60);
      timer.pause();
      clock.advance(const Duration(hours: 3));
      expect(timer.state, FocusTimerState.paused);
      expect(timer.remainingSeconds, 5 * 60);
    });

    test('finishing early is stopped and keeps work apps', () {
      final clock = _Clock(DateTime(2026, 11, 5, 10));
      final timer = FocusTimer(clock: clock.call)
        ..start(50 * 60, workAppIds: {'code'});
      clock.advance(const Duration(minutes: 12));
      final session = timer.finish()!;
      expect(session.status, FocusStatus.stopped);
      expect(session.focusedSeconds, 12 * 60);
      expect(session.plannedSeconds, 50 * 60);
      expect(session.workAppIds, ['code']);
      expect(timer.state, FocusTimerState.finished);
      timer.reset();
      expect(timer.state, FocusTimerState.idle);
    });

    test('clock moving backwards never gives negative time', () {
      final clock = _Clock(DateTime(2026, 11, 5, 10));
      final timer = FocusTimer(clock: clock.call)..start(25 * 60);
      clock.advance(const Duration(minutes: -30));
      expect(timer.elapsedSeconds, 0);
      expect(timer.remainingSeconds, 25 * 60);
      final session = timer.finish()!;
      expect(session.focusedSeconds, 0);
    });
  });

  group('FocusSession', () {
    test('round-trips through a map', () {
      final s = FocusSession(
        id: 'a',
        plannedSeconds: 1500,
        startedAt: DateTime.utc(2026, 11, 5, 9),
        endedAt: DateTime.utc(2026, 11, 5, 9, 30),
        pausedSeconds: 300,
        status: FocusStatus.completed,
        workAppIds: const ['code'],
      );
      final back = FocusSession.fromMap(s.toMap());
      expect(back.toMap(), s.toMap());
      expect(back.focusedSeconds, 1500);
    });

    test('rejects invalid maps', () {
      expect(
        () => FocusSession.fromMap({'id': 'a', 'status': 'paused'}),
        throwsFormatException,
      );
    });
  });

  group('focusAppStats', () {
    test('counts apps only inside the focus interval', () {
      final t0 = DateTime(2026, 11, 5, 10);
      DateTime at(int m) => t0.add(Duration(minutes: m));
      final sessions = [
        AppSession(appId: 'code', appName: 'Code', start: at(-10), end: at(10)),
        AppSession(
          appId: 'browser',
          appName: 'Browser',
          start: at(10),
          end: at(15),
        ),
        AppSession(appId: 'code', appName: 'Code', start: at(15), end: at(25)),
        // Outside the session entirely.
        AppSession(appId: 'chat', appName: 'Chat', start: at(30), end: at(40)),
      ];
      final index = HistoryIndex(
        sessions: sessions,
        launches: const [],
        intervals: [
          TimeInterval(
            kind: IntervalKind.coverage,
            start: at(-60),
            end: at(60),
          ),
        ],
      );
      expect(
        index.apps(LocalDay.fromDateTime(t0), LocalDay.fromDateTime(t0)),
        hasLength(3),
      );
      final stats = focusAppStats(
        sessions: sessions,
        start: at(0),
        end: at(25),
        workAppIds: {'code'},
      );
      expect(stats.distinctApps, 2);
      expect(stats.activeSeconds, 25 * 60);
      expect(stats.workSeconds, 20 * 60);
      expect(stats.workShare, closeTo(.8, 1e-9));
    });

    test('no activity gives no share', () {
      final stats = focusAppStats(
        sessions: const [],
        start: DateTime.utc(2026),
        end: DateTime.utc(2026, 1, 1, 1),
      );
      expect(stats.distinctApps, 0);
      expect(stats.workShare, isNull);
    });
  });

  group('FocusStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('reboot_focus'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('persists sessions and work apps', () async {
      final store = FocusStore(directory: dir);
      await store.load();
      final today = LocalDay(2026, 11, 5);
      await store.add(_session('1', DateTime(2026, 11, 5, 9)));
      await store.add(_session('1', DateTime(2026, 11, 5, 9)));
      await store.add(_session('2', DateTime(2026, 11, 1, 9), minutes: 10));
      await store.add(_session('3', DateTime(2026, 10, 10, 9), minutes: 50));
      await store.setWorkApps({'code', 'notes'});

      final again = FocusStore(directory: dir);
      await again.load();
      expect(again.sessions.map((s) => s.id), ['1', '2', '3']);
      expect(again.workAppIds, {'code', 'notes'});
      expect(again.totalForLastDays(7, today: today), 35 * 60);
      expect(again.totalForLastDays(30, today: today), 85 * 60);
      expect(File('${dir.path}/focus.json.new').existsSync(), isFalse);
      final json = File('${dir.path}/focus.json').readAsStringSync();
      expect(json, contains('"version": 1'));

      await again.clear();
      expect(again.sessions, isEmpty);
      expect(File('${dir.path}/focus.json').existsSync(), isFalse);
    });

    test('a damaged file is not overwritten', () async {
      final file = File('${dir.path}/focus.json')..writeAsStringSync('{oops');
      final store = FocusStore(directory: dir);
      await store.load();
      expect(store.issue, isNotNull);
      expect(store.isAvailable, isFalse);
      await store.add(_session('1', DateTime(2026, 11, 5, 9)));
      expect(store.sessions, hasLength(1), reason: 'kept in memory');
      expect(file.readAsStringSync(), '{oops');
    });

    test('unavailable store keeps history in memory', () async {
      final store = FocusStore.unavailable();
      await store.load();
      await store.add(_session('1', DateTime(2026, 11, 5, 9)));
      expect(store.sessions, hasLength(1));
      expect(store.isAvailable, isFalse);
    });
  });

  group('FocusScreen', () {
    final now = DateTime(2026, 11, 5, 12);
    DateTime at(int m) => now.add(Duration(minutes: m));
    final sessions = [
      AppSession(appId: 'code', appName: 'Code', start: at(-120), end: at(-60)),
      AppSession(
        appId: 'video',
        appName: 'Очень длинное название видеоплеера для проверки',
        start: at(-50),
        end: at(-40),
      ),
    ];
    final index = HistoryIndex(
      sessions: sessions,
      launches: const [],
      intervals: [
        TimeInterval(kind: IntervalKind.coverage, start: at(-180), end: now),
      ],
    );

    Future<void> pump(
      WidgetTester tester,
      double width,
      UsageDataMode mode,
      _Clock clock,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      final store = FocusStore.unavailable();
      await store.load();
      await store.add(_session('old', at(-300)));
      await tester.pumpWidget(
        MaterialApp(
          theme: RebootThemes.build(AppThemeId.dark),
          home: Scaffold(
            body: FocusScreen(
              key: UniqueKey(),
              store: store,
              mode: mode,
              index: mode == UsageDataMode.real ? index : null,
              sessions: mode == UsageDataMode.real ? sessions : null,
              clock: clock.call,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders across widths in DEMO and REAL', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final mode in UsageDataMode.values) {
        for (final width in [320.0, 390.0, 1100.0]) {
          await pump(tester, width, mode, _Clock(now));
          expect(tester.takeException(), isNull, reason: '$mode $width');
          expect(
            find.text(
              'REBOOT не блокирует приложения — это таймер для самоконтроля.',
            ),
            findsOneWidget,
          );
          expect(find.text('25:00'), findsOneWidget);
          if (mode == UsageDataMode.demo) {
            expect(
              find.text('Статистика приложений доступна только в режиме REAL'),
              findsOneWidget,
            );
          } else {
            expect(find.text('Code'), findsOneWidget);
          }
        }
      }
    });

    testWidgets('start, pause, resume and finish', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in [320.0, 1100.0]) {
        final clock = _Clock(at(-130));
        await pump(tester, width, UsageDataMode.real, clock);
        await tester.ensureVisible(find.text('Code'));
        await tester.tap(find.text('Code'));
        await tester.pump();
        await tester.ensureVisible(find.text('Старт'));
        await tester.tap(find.text('Старт'));
        await tester.pump();
        clock.advance(const Duration(minutes: 10));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('15:00'), findsOneWidget);
        await tester.ensureVisible(find.text('Пауза'));
        await tester.tap(find.text('Пауза'));
        await tester.pump();
        expect(find.text('Продолжить'), findsOneWidget);
        await tester.tap(find.text('Продолжить'));
        await tester.pump();
        clock.advance(const Duration(minutes: 5));
        await tester.ensureVisible(find.text('Завершить'));
        await tester.tap(find.text('Завершить'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Итоги сессии'), findsOneWidget);
        expect(find.text('Остановлена досрочно'), findsOneWidget);
        expect(find.text('Разных приложений'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'width $width');
      }
    });

    testWidgets('auto-completes and shows DEMO notice in summary', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = _Clock(now);
      await pump(tester, 390, UsageDataMode.demo, clock);
      await tester.tap(find.text('Старт'));
      await tester.pump();
      clock.advance(const Duration(minutes: 40));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Завершена по плану'), findsOneWidget);
      expect(
        find.text('Статистика приложений доступна только в режиме REAL'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('custom duration dialog validates 5–240', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pump(tester, 390, UsageDataMode.demo, _Clock(now));
      await tester.tap(find.text('Своё…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '300');
      await tester.tap(find.text('Готово'));
      await tester.pump();
      expect(find.text('От 5 до 240 минут'), findsWidgets);
      await tester.enterText(find.byType(TextField), '45');
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(find.text('45:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
