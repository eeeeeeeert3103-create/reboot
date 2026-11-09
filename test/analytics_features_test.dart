import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/insights.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/models/usage_history.dart';
import 'package:reboot_app/models/usage_report.dart';
import 'package:reboot_app/screens/analytics_screen.dart';
import 'package:reboot_app/screens/timeline_screen.dart';
import 'package:reboot_app/services/app_shell.dart';
import 'package:reboot_app/theme/reboot_themes.dart';
import 'package:reboot_app/widgets/interactive_charts.dart';

const today = LocalDay(2026, 11, 5);
DateTime at(int daysAgo, int hour, [int minute = 0]) {
  final d = today.addDays(-daysAgo);
  return DateTime(d.year, d.month, d.day, hour, minute);
}

/// [days] days with coverage; app "a" used 19:00–21:00 (evening heavy),
/// app "b" 08:00–08:30 on each day.
HistoryIndex history({int days = 14, bool previous = true}) => HistoryIndex(
  sessions: [
    for (var d = 0; d < days; d++) ...[
      AppSession(
        appId: 'a',
        appName: 'Alpha',
        start: at(d, 19),
        end: at(d, 21),
      ),
      AppSession(
        appId: 'b',
        appName: 'Beta',
        start: at(d, 8),
        end: at(d, 8, 30),
      ),
    ],
  ],
  launches: [
    for (var d = 0; d < days; d++)
      AppLaunch(appId: 'a', appName: 'Alpha', at: at(d, 19)),
  ],
  intervals: [
    for (var d = 0; d < days; d++)
      TimeInterval(
        kind: IntervalKind.coverage,
        start: at(d, 0),
        end: at(d, 23, 59),
      ),
  ],
);

void main() {
  group('hourly and heatmap', () {
    test('sessions are split into local hours', () {
      final index = history(days: 1);
      final hours = index.hourly(today);
      expect(hours[19], 3600);
      expect(hours[20], 3600);
      expect(hours[8], 1800);
      expect(hours.fold(0, (a, b) => a + b), index.day(today).activeSeconds);
    });

    test('heatmap averages over covered days per weekday only', () {
      final index = history(days: 14);
      final map = index.heatmap(today.addDays(-13), today);
      final w = today.weekday - 1;
      expect(map.coveredDays[w], 2);
      expect(map.average(w, 19), 3600);
      expect(map.average(w, 3), 0);
      expect(map.totalSeconds, 14 * (2 * 3600 + 1800));
    });

    test('app filter limits the heatmap to one app', () {
      final map = history(days: 7)
          .heatmap(today.addDays(-6), today, appId: 'b');
      expect(map.byHour[19], 0);
      expect(map.byHour[8], 7 * 1800);
    });
  });

  test('range report covers exactly the chosen days', () {
    final report = buildRangeReport(
      index: history(days: 14),
      from: today.addDays(-2),
      to: today.addDays(-1),
      goalMinutes: 120,
    );
    expect(report.days.map((d) => d.day), [
      today.addDays(-2),
      today.addDays(-1),
    ]);
    expect(report.previousDays, hasLength(2));
    expect(report.periodActiveSeconds, 2 * 9000);
    expect(report.appsPeriod!.first.appId, 'a');
    expect(report.daysWithinGoal, 0);
  });

  group('insights', () {
    test('stay silent with too little data', () {
      final index = history(days: 2, previous: false);
      final week = buildRangeReport(
        index: index,
        from: today.addDays(-6),
        to: today,
        goalMinutes: 300,
      );
      final insights = buildInsights(
        week: week,
        heatmap: index.heatmap(today.addDays(-29), today),
        heatmapDays: 2,
      );
      expect(insights, isEmpty);
    });

    test('report facts with enough data', () {
      final index = history(days: 14);
      final week = buildRangeReport(
        index: index,
        from: today.addDays(-6),
        to: today,
        goalMinutes: 300,
      );
      final titles = buildInsights(
        week: week,
        heatmap: index.heatmap(today.addDays(-13), today),
        heatmapDays: 14,
      ).map((i) => i.title).toList();
      expect(titles, contains('Экранное время почти не изменилось'));
      expect(titles, contains('Больше всего времени — в Alpha'));
      expect(titles, contains('Вечерняя активность выше, чем утренняя'));
      expect(titles, contains('Наиболее активный период — 18:00–21:00'));
      expect(titles.any((t) => t.startsWith('Самый активный день')), isTrue);
    });
  });

  test('weekly report exports real figures only', () {
    final index = history(days: 7);
    final start = weekStart(today);
    final report = WeeklyReport(
      mode: UsageDataMode.real,
      start: start,
      usage: buildRangeReport(
        index: index,
        from: start,
        to: today,
        goalMinutes: 300,
      ),
      heatmap: index.heatmap(start, today),
      streak: StreakSummary.empty(today: today, goalMinutes: 300),
      focusSeconds: 1500,
      focusSessions: 1,
    );
    final map = report.toMap();
    expect(map['mostActiveHour'], 19);
    expect((map['topApps']! as List).first['app'], 'a');
    expect(map['focus'], {'seconds': 1500, 'sessions': 1});
  });

  testWidgets('app shell forwards tray actions to the app', (tester) async {
    const channel = MethodChannel('reboot/app');
    final shell = AppShellBridge(channel: channel);
    final actions = <TrayAction>[];
    shell.onTrayAction = (a) async => actions.add(a);
    final codec = const StandardMethodCodec();
    for (final name in ['open', 'toggleCollection', 'quit', 'unknown']) {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'reboot/app',
            codec.encodeMethodCall(MethodCall('trayAction', {'action': name})),
            (_) {},
          );
    }
    expect(actions, [
      TrayAction.open,
      TrayAction.toggleCollection,
      TrayAction.quit,
    ]);
    shell.dispose();
  });

  testWidgets('tapping a bar opens that day', (tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final index = history(days: 7);
    await tester.pumpWidget(
      MaterialApp(
        theme: RebootThemes.build(AppThemeId.dark),
        home: Scaffold(
          body: AnalyticsScreen(
            mode: UsageDataMode.real,
            today: today,
            goalMinutes: 300,
            streak: StreakSummary.empty(today: today, goalMinutes: 300),
            index: index,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chart = find.byType(InteractiveBarChart);
    final box = tester.getRect(chart);
    // Last bar (today) sits at the right edge of the plot.
    await tester.tapAt(Offset(box.right - 20, box.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('По часам'), findsOneWidget);
    expect(find.textContaining('Alpha'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timeline lists sessions and gaps, never fills them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final index = HistoryIndex(
      sessions: [
        AppSession(
          appId: 'a',
          appName: 'Alpha',
          start: at(1, 10),
          end: at(1, 11),
        ),
      ],
      launches: const [],
      intervals: [
        TimeInterval(
          kind: IntervalKind.coverage,
          start: at(1, 9),
          end: at(1, 12),
        ),
        TimeInterval(
          kind: IntervalKind.idle,
          start: at(1, 11),
          end: at(1, 11, 30),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: RebootThemes.build(AppThemeId.dark),
        home: Scaffold(
          body: TimelineScreen(
            mode: UsageDataMode.real,
            today: today,
            index: index,
            initialDay: today.addDays(-1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Бездействие'), findsWidgets);
    expect(find.text('Сбор не шёл'), findsWidgets);
    await tester.tap(find.text('Alpha').last);
    await tester.pumpAndSettle();
    expect(find.text('Длительность'), findsOneWidget);
  });
}
