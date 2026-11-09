import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/app_goal.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/models/usage_history.dart';
import 'package:reboot_app/models/usage_report.dart';
import 'package:reboot_app/screens/app_goals_screen.dart';
import 'package:reboot_app/services/app_goal_store.dart';
import 'package:reboot_app/theme/reboot_themes.dart';

final _now = DateTime(2026, 11, 5, 18);
final _today = LocalDay.fromDateTime(_now);

DateTime _noonOf(LocalDay d) => DateTime(d.year, d.month, d.day, 12);

AppGoal _goal({
  String app = 'video',
  int limit = 60,
  bool warn = true,
  String? name,
}) => AppGoal(
  appId: app,
  appName: name ?? app,
  dailyLimitMinutes: limit,
  warnEnabled: warn,
  createdAt: DateTime.utc(2026, 11, 1),
);

/// [minutesByDayAgo]: usage of `video` per day offset (0 = today).
/// Days listed in [uncovered] have no collector coverage.
HistoryIndex _index(
  Map<int, int> minutesByDayAgo, {
  Set<int> uncovered = const {},
}) {
  final sessions = <AppSession>[];
  final intervals = <TimeInterval>[];
  for (var ago = 0; ago <= 20; ago++) {
    final day = _today.addDays(-ago);
    final noon = _noonOf(day);
    if (!uncovered.contains(ago)) {
      intervals.add(
        TimeInterval(
          kind: IntervalKind.coverage,
          start: DateTime(day.year, day.month, day.day, 8),
          end: DateTime(day.year, day.month, day.day, 17),
        ),
      );
    }
    final minutes = minutesByDayAgo[ago] ?? 0;
    if (minutes > 0) {
      sessions.add(
        AppSession(
          appId: 'video',
          appName: 'Video',
          start: noon,
          end: noon.add(Duration(minutes: minutes)),
        ),
      );
    }
  }
  sessions.add(
    AppSession(
      appId: 'code',
      appName: 'Code',
      start: _noonOf(_today).subtract(const Duration(hours: 2)),
      end: _noonOf(_today).subtract(const Duration(hours: 1)),
    ),
  );
  return HistoryIndex(
    sessions: sessions,
    launches: const [],
    intervals: intervals,
  );
}

void main() {
  group('AppGoal', () {
    test('validates the limit and round-trips', () {
      expect(() => _goal(limit: 4), throwsArgumentError);
      expect(() => _goal(limit: 601), throwsArgumentError);
      final goal = _goal(limit: 600, warn: false);
      final back = AppGoal.fromMap(goal.toMap());
      expect(back.toMap(), goal.toMap());
      expect(
        () => AppGoal.fromMap({...goal.toMap(), 'dailyLimitMinutes': 1}),
        throwsFormatException,
      );
    });

    test('thresholds', () {
      expect(goalStatusFor(.79), AppGoalStatus.ok);
      expect(goalStatusFor(.8), AppGoalStatus.near);
      expect(goalStatusFor(.99), AppGoalStatus.near);
      expect(goalStatusFor(1), AppGoalStatus.reached);
      expect(goalStatusFor(1.5), AppGoalStatus.reached);
    });
  });

  group('AppGoalProgress', () {
    test('today usage, fraction and status', () {
      final progress = AppGoalProgress.compute(
        goal: _goal(),
        index: _index({0: 45}),
        today: _today,
      );
      expect(progress.usedSeconds, 45 * 60);
      expect(progress.fraction, .75);
      expect(progress.status, AppGoalStatus.ok);
      expect(progress.remainingSeconds, 15 * 60);

      final near = AppGoalProgress.compute(
        goal: _goal(),
        index: _index({0: 48}),
        today: _today,
      );
      expect(near.status, AppGoalStatus.near);
      final reached = AppGoalProgress.compute(
        goal: _goal(),
        index: _index({0: 70}),
        today: _today,
      );
      expect(reached.status, AppGoalStatus.reached);
      expect(reached.remainingSeconds, 0);
    });

    test('14 finished days; uncovered days are no data, not success', () {
      final progress = AppGoalProgress.compute(
        goal: _goal(),
        index: _index({1: 30, 2: 90, 3: 0, 14: 61}, uncovered: {3, 5}),
        today: _today,
      );
      expect(progress.history, hasLength(14));
      expect(progress.history.first.day, _today.addDays(-14));
      expect(progress.history.last.day, _today.addDays(-1));
      GoalDayResult at(int ago) => progress.history
          .firstWhere((d) => d.day == _today.addDays(-ago))
          .result;
      expect(at(1), GoalDayResult.met);
      expect(at(2), GoalDayResult.exceeded);
      expect(at(3), GoalDayResult.noData);
      expect(at(5), GoalDayResult.noData);
      expect(at(14), GoalDayResult.exceeded);
      expect(progress.daysWithData, 12);
      expect(progress.metDays, 10);
    });
  });

  group('pendingAlerts', () {
    test('once per day per threshold, only with warnings on', () {
      final goals = [_goal(), _goal(app: 'code', limit: 60, warn: false)];
      final shown = <String>{};

      var alerts = pendingAlerts(goals, _index({0: 30}), _today, shown);
      expect(alerts, isEmpty);

      alerts = pendingAlerts(goals, _index({0: 50}), _today, shown);
      expect(alerts.single.status, AppGoalStatus.near);
      expect(alerts.single.goal.appId, 'video');
      shown.addAll(alerts.map((a) => a.key));
      expect(pendingAlerts(goals, _index({0: 55}), _today, shown), isEmpty);

      alerts = pendingAlerts(goals, _index({0: 61}), _today, shown);
      expect(alerts.single.status, AppGoalStatus.reached);
      expect(alerts.single.message, contains('61 из 60'));
      shown.addAll(alerts.map((a) => a.key));
      expect(pendingAlerts(goals, _index({0: 90}), _today, shown), isEmpty);

      // A new day starts over.
      final tomorrow = _today.addDays(1);
      expect(
        AppGoalAlert.alertKey('video', tomorrow, AppGoalStatus.near),
        isNot(isIn(shown)),
      );
    });

    test('jumping straight past the limit gives only "reached"', () {
      final alerts = pendingAlerts([_goal()], _index({0: 80}), _today, {});
      expect(alerts.single.status, AppGoalStatus.reached);
      final after = pendingAlerts(
        [_goal()],
        _index({0: 80}),
        _today,
        alerts.map((a) => a.key).toSet(),
      );
      expect(after, isEmpty);
    });

    test('no REAL history means no alerts', () {
      expect(pendingAlerts([_goal()], null, _today, {}), isEmpty);
    });
  });

  group('AppGoalStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('reboot_goals'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('add, update, remove and reload', () async {
      final store = AppGoalStore(directory: dir);
      await store.load();
      expect(await store.add(_goal()), isTrue);
      expect(await store.add(_goal()), isFalse);
      expect(await store.add(_goal(app: 'chat')), isTrue);
      expect(
        await store.update(_goal().copyWith(dailyLimitMinutes: 30)),
        isTrue,
      );
      expect(await store.update(_goal(app: 'none')), isFalse);
      expect(await store.remove('chat'), isTrue);
      expect(await store.remove('chat'), isFalse);

      final again = AppGoalStore(directory: dir);
      await again.load();
      expect(again.goals.single.appId, 'video');
      expect(again.goals.single.dailyLimitMinutes, 30);
      expect(File('${dir.path}/app_goals.json.new').existsSync(), isFalse);
      expect(
        File('${dir.path}/app_goals.json').readAsStringSync(),
        contains('"version": 1'),
      );

      await again.clear();
      expect(again.goals, isEmpty);
      expect(File('${dir.path}/app_goals.json').existsSync(), isFalse);
    });

    test('a damaged file is reported and not overwritten', () async {
      final file = File('${dir.path}/app_goals.json')
        ..writeAsStringSync('{"version": 1, "goals": [{"app": 3}]}');
      final store = AppGoalStore(directory: dir);
      await store.load();
      expect(store.issue, isNotNull);
      expect(store.goals, isEmpty);
      await store.add(_goal());
      expect(store.goals, hasLength(1));
      expect(file.readAsStringSync(), contains('"app": 3'));
    });

    test('unsupported version is rejected', () async {
      File('${dir.path}/app_goals.json')
          .writeAsStringSync('{"version": 2, "goals": []}');
      final store = AppGoalStore(directory: dir);
      await store.load();
      expect(store.issue, isNotNull);
      expect(store.isAvailable, isFalse);
    });
  });

  group('AppGoalsScreen', () {
    Future<AppGoalStore> pump(
      WidgetTester tester,
      double width,
      UsageDataMode mode, {
      bool withGoals = true,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      final store = AppGoalStore.unavailable();
      await store.load();
      if (withGoals) {
        await store.add(
          _goal(limit: 60, name: 'Видеоплеер с очень длинным названием'),
        );
        await store.add(
          _goal(app: 'code', limit: 600, warn: false, name: 'Code'),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: RebootThemes.build(AppThemeId.dark),
          home: Scaffold(
            body: AppGoalsScreen(
              key: UniqueKey(),
              store: store,
              mode: mode,
              index: mode == UsageDataMode.real
                  ? _index({0: 45, 1: 30, 2: 90}, uncovered: {4})
                  : null,
              clock: () => _now,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('renders across widths in DEMO and REAL', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final mode in UsageDataMode.values) {
        for (final width in [320.0, 390.0, 1100.0]) {
          await pump(tester, width, mode);
          expect(tester.takeException(), isNull, reason: '$mode $width');
          if (mode == UsageDataMode.demo) {
            expect(
              find.text('Прогресс считается только по данным REAL'),
              findsNWidgets(2),
            );
          } else {
            expect(find.text('45 мин из 1 ч'), findsOneWidget);
            expect(find.text('Почти у цели'), findsNothing);
          }
        }
      }
    });

    testWidgets('empty state renders', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in [320.0, 1100.0]) {
        await pump(tester, width, UsageDataMode.real, withGoals: false);
        expect(find.text('Целей пока нет'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('add, edit and remove a goal', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final mode in UsageDataMode.values) {
        for (final width in [320.0, 1100.0]) {
          final store = await pump(tester, width, mode, withGoals: false);
          await tester.tap(find.text('Добавить цель').first);
          await tester.pumpAndSettle();
          expect(find.text('Новая цель'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '$mode $width add');
          await tester.tap(find.text('Сохранить'));
          await tester.pumpAndSettle();
          expect(store.goals, hasLength(1));
          final appId = store.goals.single.appId;

          await tester.tap(find.byTooltip('Действия'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Изменить'));
          await tester.pumpAndSettle();
          expect(find.text('Изменить цель'), findsOneWidget);
          // First switch: reminder; the second one is the soft limit.
          await tester.tap(find.byType(Switch).first);
          await tester.pump();
          await tester.tap(find.text('Сохранить'));
          await tester.pumpAndSettle();
          expect(store.goalFor(appId)!.warnEnabled, isFalse);

          await tester.tap(find.byTooltip('Действия'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Удалить'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
          await tester.pumpAndSettle();
          expect(store.goals, isEmpty);
          expect(tester.takeException(), isNull, reason: '$mode $width');
        }
      }
    });
  });
}
