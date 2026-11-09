import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/app.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/models/usage_data.dart';
import 'package:reboot_app/models/usage_history.dart';
import 'package:reboot_app/models/usage_report.dart';
import 'package:reboot_app/screens/analytics_screen.dart';
import 'package:reboot_app/screens/dashboard_screen.dart';
import 'package:reboot_app/screens/insights_screen.dart';
import 'package:reboot_app/screens/timeline_screen.dart';
import 'package:reboot_app/services/consent_store.dart';
import 'package:reboot_app/services/privacy_data_store.dart';
import 'package:reboot_app/services/user_settings_store.dart';
import 'package:reboot_app/theme/reboot_themes.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('reboot/settings');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(
    () => messenger.setMockMethodCallHandler(
      channel,
      (call) async => UserSettings.defaults.toMap(),
    ),
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('first launch shows onboarding; skipping lands in DEMO', (
    tester,
  ) async {
    phone(tester);
    final consent = ConsentStore.inMemory();
    final collector = FakeCollector();
    await tester.pumpWidget(
      RebootApp(
        settingsStore: testSettingsStore(),
        privacyDataStore: PrivacyDataStore.unavailable(),
        consentStore: consent,
        collector: collector,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Добро пожаловать в REBOOT'), findsOneWidget);

    await tester.tap(find.text('Пропустить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('С возвращением'), findsOneWidget);
    expect(find.text('ДЕМО-ДАННЫЕ'), findsOneWidget);
    expect(consent.choices.onboardingCompleted, isTrue);
    expect(consent.choices.collectionConsent, isFalse);
    expect(collector.startCalls, 0);
  });

  testWidgets('onboarding with consent and REAL starts collection', (
    tester,
  ) async {
    phone(tester);
    final consent = ConsentStore.inMemory();
    final collector = FakeCollector();
    await tester.pumpWidget(
      RebootApp(
        settingsStore: testSettingsStore(),
        privacyDataStore: PrivacyDataStore.unavailable(),
        consentStore: consent,
        collector: collector,
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Далее'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Источник данных и согласие'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Далее'));
    await tester.pumpAndSettle();
    expect(find.text('Фон и автозапуск'), findsOneWidget);
    await tester.tap(find.text('Далее'));
    await tester.pumpAndSettle();
    expect(find.text('Разрешения системы'), findsOneWidget);
    await tester.tap(find.text('Перейти к обзору'));
    await tester.pumpAndSettle();

    expect(consent.choices.collectionConsent, isTrue);
    expect(consent.choices.preferRealData, isTrue);
    expect(collector.startCalls, 1);
    expect(find.text('ДАННЫЕ УСТРОЙСТВА'), findsOneWidget);
    expect(find.text('Данных за сегодня пока нет'), findsOneWidget);
  });

  testWidgets('REAL is unavailable in onboarding without a collector', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(
      RebootApp(
        settingsStore: testSettingsStore(),
        privacyDataStore: PrivacyDataStore.unavailable(),
        consentStore: ConsentStore.inMemory(),
        collector: FakeCollector(available: false),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Далее'));
      await tester.pumpAndSettle();
    }
    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.onChanged, isNull);
    expect(find.textContaining('Недоступно'), findsOneWidget);
  });

  testWidgets('consent in the Privacy Center asks first, then can be revoked', (
    tester,
  ) async {
    phone(tester);
    final consent = onboardedDemo();
    final collector = FakeCollector();
    await tester.pumpWidget(
      RebootApp(
        settingsStore: testSettingsStore(),
        privacyDataStore: PrivacyDataStore.unavailable(),
        consentStore: consent,
        collector: collector,
      ),
    );
    await tester.pumpAndSettle();
    await openSection(tester, 'Приватность');

    final toggle = find.ancestor(
      of: find.text('Согласие на сбор статистики'),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Разрешить сбор статистики?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(consent.choices.collectionConsent, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Разрешить'));
    await tester.pumpAndSettle();
    expect(consent.choices.collectionConsent, isTrue);
    expect(collector.startCalls, 0, reason: 'REAL not chosen yet');

    await tester.tap(find.text('REAL'));
    await tester.pumpAndSettle();
    expect(collector.collecting, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(consent.choices.collectionConsent, isFalse);
    expect(collector.collecting, isFalse);
  });

  group('screens render REAL, empty and DEMO data without layout errors', () {
    final today = LocalDay.today();
    DateTime at(int daysAgo, int hour, [int minute = 0]) {
      final d = today.addDays(-daysAgo);
      return DateTime(d.year, d.month, d.day, hour, minute);
    }

    final sessions = <AppSession>[
      for (var d = 0; d < 20; d++) ...[
        AppSession(
          appId: 'com.example.very-long-application-identifier-$d',
          appName: 'Очень длинное название приложения номер $d для проверки',
          start: at(d, 9),
          end: at(d, 11, d),
        ),
        AppSession(
          appId: 'com.apple.Safari',
          appName: 'Safari',
          start: at(d, 13),
          end: at(d, 13 + d % 9, 30),
        ),
      ],
    ];
    final index = HistoryIndex(
      sessions: sessions,
      launches: [
        for (var d = 0; d < 20; d++)
          AppLaunch(
            appId: 'com.apple.Safari',
            appName: 'Safari',
            at: at(d, 13),
          ),
      ],
      intervals: [
        for (var d = 0; d < 20; d++) ...[
          TimeInterval(
            kind: IntervalKind.coverage,
            start: at(d, 0),
            end: at(d, 23, 59),
          ),
          TimeInterval(
            kind: IntervalKind.idle,
            start: at(d, 12),
            end: at(d, 12, 20),
          ),
          TimeInterval(
            kind: IntervalKind.locked,
            start: at(d, 12, 20),
            end: at(d, 12, 50),
          ),
        ],
      ],
    );
    final emptyIndex = HistoryIndex(
      sessions: const [],
      launches: const [],
      intervals: const [],
    );
    final demo = buildDemoReport(demoUsage.withTarget(300));

    for (final (name, report, idx) in [
      (
        'real 7',
        buildRealReport(index: index, today: today, goalMinutes: 300),
        index,
      ),
      (
        'real 30',
        buildRealReport(
          index: index,
          today: today,
          goalMinutes: 300,
          periodDays: 30,
        ),
        index,
      ),
      (
        'real empty',
        buildRealReport(index: emptyIndex, today: today, goalMinutes: 300),
        emptyIndex,
      ),
      ('demo', demo, null),
    ]) {
      testWidgets(name, (tester) async {
        final streak = StreakCalculator.summarize(
          days:
              idx?.completedStreakDays(today: today, goalMinutes: 300) ??
              const [],
          today: today,
          goalMinutes: 300,
          todayMinutes: report.todayUsage.activeMinutes,
        );
        for (final width in [320.0, 390.0, 760.0, 1100.0, 1440.0]) {
          for (final theme in [AppThemeId.dark, AppThemeId.light]) {
            tester.view.physicalSize = Size(width, 1000);
            tester.view.devicePixelRatio = 1;
            for (final screen in <Widget>[
              DashboardScreen(
                displayName: 'Тест',
                report: report,
                streak: streak,
              ),
              AnalyticsScreen(
                mode: report.mode,
                today: report.today,
                goalMinutes: 300,
                streak: streak,
                index: idx,
                demoReport: idx == null ? report : null,
              ),
              InsightsScreen(
                mode: report.mode,
                today: report.today,
                goalMinutes: 300,
                streak: streak,
                index: idx,
                demoReport: idx == null ? report : null,
              ),
              TimelineScreen(
                mode: report.mode,
                today: report.today,
                index: idx,
              ),
            ]) {
              await tester.pumpWidget(
                MaterialApp(
                  theme: RebootThemes.build(theme),
                  home: Scaffold(body: screen),
                ),
              );
              await tester.pump();
              expect(
                tester.takeException(),
                isNull,
                reason: '$name ${screen.runtimeType} $width ${theme.name}',
              );
            }
          }
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets('app details dialog lays out long names', (tester) async {
      final report = buildRealReport(
        index: index,
        today: today,
        goalMinutes: 300,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: RebootThemes.build(AppThemeId.dark),
          home: Scaffold(
            body: AnalyticsScreen(
              mode: report.mode,
              today: today,
              goalMinutes: 300,
              streak: StreakSummary.empty(today: today, goalMinutes: 300),
              index: index,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tile = find.textContaining('Очень длинное название').first;
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text('САМАЯ ДЛИННАЯ'), findsOneWidget);
      expect(find.textContaining('История сессий'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
