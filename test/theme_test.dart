import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/app.dart';
import 'package:reboot_app/models/streak.dart';
import 'package:reboot_app/services/privacy_data_store.dart';
import 'package:reboot_app/services/streak_store.dart';
import 'package:reboot_app/services/user_settings_store.dart';
import 'package:reboot_app/theme/reboot_themes.dart';

import 'support/fakes.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('reboot/settings');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('theme registry', () {
    test('every theme id has one definition with a readable palette', () {
      expect(
        RebootThemes.all.map((t) => t.id).toSet(),
        AppThemeId.values.toSet(),
      );
      expect(
        RebootThemes.all.map((t) => t.name).toSet(),
        hasLength(AppThemeId.values.length),
      );
      for (final definition in RebootThemes.all) {
        final p = definition.palette;
        expect(
          _contrast(p.text, p.background),
          greaterThan(7),
          reason: definition.name,
        );
        expect(
          _contrast(p.muted, p.surface),
          greaterThan(3),
          reason: definition.name,
        );
        expect(
          _contrast(p.onAccent, p.accent),
          greaterThan(3),
          reason: definition.name,
        );
        expect(p.categoryColors, hasLength(4));
      }
    });

    test('built themes expose their palette and brightness', () {
      for (final id in AppThemeId.values) {
        final theme = RebootThemes.build(id);
        final palette = theme.extension<RebootPalette>();
        expect(palette, same(RebootThemes.byId(id).palette));
        expect(theme.brightness, palette!.brightness);
        expect(theme.scaffoldBackgroundColor, palette.background);
      }
      expect(RebootThemes.build(AppThemeId.light).brightness, Brightness.light);
    });

    test('unknown stored values fall back to REBOOT Dark', () {
      expect(RebootThemes.parse('neon'), AppThemeId.dark);
      expect(RebootThemes.parse(null), AppThemeId.dark);
      expect(RebootThemes.parse('emerald'), AppThemeId.emerald);
    });
  });

  testWidgets('saved theme is applied on start', (tester) async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => const UserSettings(themeId: AppThemeId.emerald).toMap(),
    );
    await tester.pumpWidget(
      RebootApp(
        settingsStore: UserSettingsStore(channel: channel),
        privacyDataStore: PrivacyDataStore.unavailable(),
        consentStore: onboardedDemo(),
        collector: FakeCollector(),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(AppShell));
    expect(
      context.palette.accent,
      RebootThemes.byId(AppThemeId.emerald).palette.accent,
    );
  });

  testWidgets('choosing a theme restyles the app at once and is saved', (
    tester,
  ) async {
    final saved = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveSettings') {
        saved.add(call.arguments as Map<Object?, Object?>);
      }
      return UserSettings.defaults.toMap();
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      RebootApp(
        settingsStore: UserSettingsStore(channel: channel),
        privacyDataStore: PrivacyDataStore.unavailable(),
        consentStore: onboardedDemo(),
        collector: FakeCollector(),
      ),
    );
    await tester.pumpAndSettle();
    await openSection(tester, 'Профиль');

    final option = find.bySemanticsLabel('Тема REBOOT Light');
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(AppShell));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(saved.last['themeId'], 'light');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every theme renders all sections without layout errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final id in AppThemeId.values) {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => UserSettings(themeId: id).toMap(),
      );
      await tester.pumpWidget(
        RebootApp(
          key: ValueKey(id),
          settingsStore: UserSettingsStore(channel: channel),
          privacyDataStore: PrivacyDataStore.unavailable(),
          consentStore: onboardedDemo(),
          collector: FakeCollector(),
        ),
      );
      await tester.pumpAndSettle();
      for (final section in [
        'Аналитика',
        'Лента',
        'Фокус',
        'Цели',
        'Отчёт',
        'Приватность',
        'Профиль',
        'Обзор',
      ]) {
        await openSection(tester, section);
      }
      expect(tester.takeException(), isNull, reason: id.name);
    }
  });

  testWidgets('demo streak is labelled and never written to the ledger', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => UserSettings.defaults.toMap(),
    );
    final streakStore = _SpyStreakStore();
    await tester.pumpWidget(
      RebootApp(
        settingsStore: UserSettingsStore(channel: channel),
        privacyDataStore: PrivacyDataStore.unavailable(),
        streakStore: streakStore,
        consentStore: onboardedDemo(),
        collector: FakeCollector(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('ДЕМО · не засчитывается'), findsWidgets);
    await openSection(tester, 'Аналитика');
    expect(find.text('Календарь серии'), findsOneWidget);
    expect(find.text('История дней'), findsOneWidget);
    expect(streakStore.recordCalls, 0);
  });
}

class _SpyStreakStore extends StreakStore {
  _SpyStreakStore() : super.unavailable();

  int recordCalls = 0;

  @override
  Future<int> recordCompletedDays(
    Iterable<StreakDay> candidates, {
    required LocalDay today,
  }) async {
    recordCalls++;
    return 0;
  }
}
