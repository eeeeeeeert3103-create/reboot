import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/services/user_settings_store.dart';
import 'package:reboot_app/theme/reboot_themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('reboot/settings');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'loads native settings and falls back to safe defaults for bad fields',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
          'profileName': '  Taylor Example  ',
          'notifications': false,
          'weeklySummary': 'invalid',
          'goalHours': 99,
          'themeId': 'neon',
        },
      );

      final settings = await UserSettingsStore(channel: channel).loadSettings();

      expect(settings.notifications, isFalse);
      expect(settings.profileName, 'Taylor Example');
      expect(settings.weeklySummary, isTrue);
      expect(settings.goalHours, 10);
      expect(settings.themeId, AppThemeId.dark);
    },
  );

  test('surfaces an error when native settings cannot be read', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'storage_error');
    });

    expect(
      () => UserSettingsStore(channel: channel).loadSettings(),
      throwsA(isA<UserSettingsStoreException>()),
    );
  });

  test('surfaces a missing native settings handler', () async {
    messenger.setMockMethodCallHandler(channel, null);

    expect(
      () => UserSettingsStore(channel: channel).loadSettings(),
      throwsA(isA<UserSettingsStoreException>()),
    );
  });

  test('saves all settings through the method channel', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    const settings = UserSettings(
      profileName: 'Taylor Example',
      notifications: false,
      weeklySummary: true,
      goalHours: 7.5,
    );

    await UserSettingsStore(channel: channel).saveSettings(settings);

    expect(received?.method, 'saveSettings');
    expect(received?.arguments, settings.toMap());
  });

  test('wraps native save errors with a typed store exception', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'storage_error');
    });

    expect(
      () =>
          UserSettingsStore(channel: channel)
              .saveSettings(UserSettings.defaults),
      throwsA(isA<UserSettingsStoreException>()),
    );
  });

  test(
    'file-backed settings survive reopening and are deleted locally',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'reboot-settings-file-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const expected = UserSettings(
        profileName: 'Local Test Profile',
        notifications: false,
        weeklySummary: true,
        goalHours: 7.5,
        themeId: AppThemeId.midnightBlue,
      );
      final store = UserSettingsStore(localDirectory: directory);
      await store.saveSettings(expected);

      final reopened = UserSettingsStore(localDirectory: directory);
      expect(await reopened.loadSettings(), expected);

      await reopened.deleteSettings();
      expect(await reopened.loadSettings(), UserSettings.defaults);
      expect(
        await File('${directory.path}${Platform.pathSeparator}settings.json')
            .exists(),
        isFalse,
      );
    },
  );

  test('deletes native settings through the platform channel', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await UserSettingsStore(channel: channel).deleteSettings();

    expect(received?.method, 'deleteSettings');
  });
}
