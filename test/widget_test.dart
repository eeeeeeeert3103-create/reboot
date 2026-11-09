import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/app.dart';
import 'package:reboot_app/models/usage_data.dart';
import 'package:reboot_app/services/privacy_data_store.dart';
import 'package:reboot_app/services/user_settings_store.dart';
import 'package:reboot_app/theme/reboot_themes.dart';
import 'package:reboot_app/widgets/usage_source_state.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const settingsChannel = MethodChannel('reboot/settings');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(
    () => messenger.setMockMethodCallHandler(
      settingsChannel,
      (call) async => UserSettings.defaults.toMap(),
    ),
  );
  tearDown(() => messenger.setMockMethodCallHandler(settingsChannel, null));

  testWidgets('dashboard presents clearly labelled demonstration data', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('С возвращением,\nАлександр Иванов'), findsOneWidget);
    expect(find.text('5 ч 42 мин'), findsOneWidget);
    expect(find.text('ДЕМО-ДАННЫЕ'), findsOneWidget);
    expect(find.textContaining('не получена с устройства'), findsOneWidget);
  });

  testWidgets('settings read errors block defaults and offer retry', (
    tester,
  ) async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(settingsChannel, (call) async {
      attempts++;
      if (attempts == 1) {
        throw PlatformException(code: 'storage_error');
      }
      return UserSettings.defaults.toMap();
    });

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('Настройки не удалось прочитать'), findsOneWidget);
    expect(find.text('ДЕМО-ДАННЫЕ'), findsNothing);
    expect(find.text('Повторить'), findsOneWidget);

    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('ДЕМО-ДАННЫЕ'), findsOneWidget);
  });

  testWidgets('all sections can be opened from compact navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    await openSection(tester, 'Аналитика');
    expect(
      find.text('Динамика демонстрационных примеров за 7 дней'),
      findsOneWidget,
    );

    await openSection(tester, 'Лента');
    expect(find.text('Лента доступна только в режиме REAL'), findsOneWidget);

    await openSection(tester, 'Фокус');
    expect(find.textContaining('не блокирует'), findsWidgets);

    await openSection(tester, 'Цели');
    expect(find.textContaining('REAL'), findsWidgets);

    await openSection(tester, 'Отчёт');
    expect(
      find.text('Три идеи для самостоятельного эксперимента'),
      findsOneWidget,
    );

    await openSection(tester, 'Приватность');
    expect(find.text('Центр приватности'), findsOneWidget);
    expect(find.text('Согласие на сбор статистики'), findsOneWidget);

    await openSection(tester, 'Профиль');
    expect(find.text('Цель экранного времени'), findsOneWidget);
    expect(find.text('Тема оформления'), findsOneWidget);
  });

  testWidgets('settings have no switches that do nothing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();
    await openSection(tester, 'Профиль');

    // The old notification switches stored a preference that did nothing.
    expect(find.text('Мягкие напоминания'), findsNothing);
    expect(find.textContaining('не отправляет уведомлений'), findsOneWidget);
    // Background and login switches exist but are disabled, with a reason,
    // when the native shell is unavailable (as in tests).
    final switches = tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    // Background, login item (disabled here) and the local AI opt-in.
    expect(switches, hasLength(3));
    expect(switches.where((s) => s.onChanged == null), hasLength(2));
    expect(find.textContaining('Недоступно в этой сборке'), findsWidgets);
  });

  testWidgets('goal change is saved and keeps other settings', (tester) async {
    MethodCall? saved;
    messenger.setMockMethodCallHandler(settingsChannel, (call) async {
      if (call.method == 'saveSettings') saved = call;
      return const UserSettings(themeId: AppThemeId.violet).toMap();
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();
    await openSection(tester, 'Профиль');
    final slider = find.byType(Slider);
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(200, 0));
    await tester.pumpAndSettle();

    final args = saved?.arguments as Map<Object?, Object?>;
    expect(args['goalHours'], greaterThan(6));
    expect(args['themeId'], 'violet');
  });

  testWidgets('source states have distinct, truthful messages', (tester) async {
    const expected = {
      UsageSourceState.demo: 'Демо-пример',
      UsageSourceState.loading: 'Загружаем сводку',
      UsageSourceState.empty: 'Нет данных за период',
      UsageSourceState.permissionDenied: 'Доступ не предоставлен',
    };
    for (final entry in expected.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: UsageSourceNotice(state: entry.key)),
        ),
      );
      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'dashboard and navigation render without layout errors across widths',
    (tester) async {
      for (final width in [320.0, 390.0, 800.0, 899.0, 900.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(_testApp());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width $width');
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}

RebootApp _testApp() => RebootApp(
  settingsStore: testSettingsStore(),
  privacyDataStore: PrivacyDataStore.unavailable(),
  consentStore: onboardedDemo(),
  collector: FakeCollector(),
);
