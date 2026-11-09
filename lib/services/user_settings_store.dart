import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../theme/reboot_themes.dart';

/// User-configurable preferences persisted by the platform.
class UserSettings {
  const UserSettings({
    this.profileName = 'Александр Иванов',
    this.notifications = true,
    this.weeklySummary = true,
    this.goalHours = 6,
    this.themeId = RebootThemes.fallback,
  });

  static const defaults = UserSettings();

  final bool notifications;
  final String profileName;
  final bool weeklySummary;
  final double goalHours;
  final AppThemeId themeId;

  factory UserSettings.fromMap(Map<Object?, Object?> map) {
    final rawGoal = map['goalHours'];
    final goal = rawGoal is num ? rawGoal.toDouble() : defaults.goalHours;
    final rawProfileName = map['profileName'];
    final profileName = rawProfileName is String ? rawProfileName.trim() : '';
    return UserSettings(
      profileName: profileName.isNotEmpty && profileName.length <= 80
          ? profileName
          : defaults.profileName,
      notifications: map['notifications'] is bool
          ? map['notifications']! as bool
          : defaults.notifications,
      weeklySummary: map['weeklySummary'] is bool
          ? map['weeklySummary']! as bool
          : defaults.weeklySummary,
      goalHours: goal.isFinite
          ? goal.clamp(2, 10).toDouble()
          : defaults.goalHours,
      themeId: RebootThemes.parse(map['themeId']),
    );
  }

  Map<String, Object> toMap() => {
    'profileName': profileName,
    'notifications': notifications,
    'weeklySummary': weeklySummary,
    'goalHours': goalHours,
    'themeId': themeId.name,
  };

  UserSettings copyWith({
    String? profileName,
    bool? notifications,
    bool? weeklySummary,
    double? goalHours,
    AppThemeId? themeId,
  }) => UserSettings(
    profileName: profileName ?? this.profileName,
    notifications: notifications ?? this.notifications,
    weeklySummary: weeklySummary ?? this.weeklySummary,
    goalHours: goalHours ?? this.goalHours,
    themeId: themeId ?? this.themeId,
  );

  @override
  bool operator ==(Object other) =>
      other is UserSettings &&
      other.notifications == notifications &&
      other.profileName == profileName &&
      other.weeklySummary == weeklySummary &&
      other.goalHours == goalHours &&
      other.themeId == themeId;

  @override
  int get hashCode => Object.hash(
    profileName,
    notifications,
    weeklySummary,
    goalHours,
    themeId,
  );
}

class UserSettingsStoreException implements Exception {
  const UserSettingsStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'UserSettingsStoreException: $message';
}

/// A dependency-free bridge to native preferences via `reboot/settings`.
class UserSettingsStore {
  /// Storage is chosen once: an explicit [localDirectory] means a JSON file,
  /// an explicit [channel] means native preferences. With neither, Windows
  /// uses `%LOCALAPPDATA%\REBOOT\settings.json` and other platforms the
  /// `reboot/settings` channel.
  UserSettingsStore({MethodChannel? channel, Directory? localDirectory})
    : _channel = channel ?? const MethodChannel('reboot/settings'),
      _localDirectory =
          localDirectory ??
          (channel == null ? _resolveWindowsDirectory() : null),
      _usesFile =
          localDirectory != null || (channel == null && Platform.isWindows);

  final MethodChannel _channel;
  final Directory? _localDirectory;
  final bool _usesFile;
  static const _settingsFileName = 'settings.json';

  static Directory? _resolveWindowsDirectory() {
    if (!Platform.isWindows) return null;
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    if (localAppData == null || localAppData.isEmpty) return null;
    return Directory('$localAppData${Platform.pathSeparator}REBOOT');
  }

  void _checkWindowsDirectory() {
    if (_usesFile && _localDirectory == null) {
      throw const UserSettingsStoreException(
        'Windows local application data directory is unavailable.',
      );
    }
  }

  Future<UserSettings> loadSettings() async {
    _checkWindowsDirectory();
    final localDirectory = _localDirectory;
    if (localDirectory != null) {
      final file = File(
        '${localDirectory.path}${Platform.pathSeparator}$_settingsFileName',
      );
      if (!await file.exists()) return UserSettings.defaults;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<Object?, Object?>) {
          throw const FormatException('Settings must be a JSON object.');
        }
        return UserSettings.fromMap(decoded);
      } on Object catch (error) {
        throw UserSettingsStoreException('Could not read settings.', error);
      }
    }
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'loadSettings',
      );
      return result == null
          ? UserSettings.defaults
          : UserSettings.fromMap(result);
    } on PlatformException catch (error) {
      throw UserSettingsStoreException('Could not read settings.', error);
    } on MissingPluginException catch (error) {
      throw UserSettingsStoreException(
        'Settings storage is unavailable.',
        error,
      );
    }
  }

  Future<void> saveSettings(UserSettings settings) async {
    _checkWindowsDirectory();
    final localDirectory = _localDirectory;
    if (localDirectory != null) {
      try {
        await localDirectory.create(recursive: true);
        final file = File(
          '${localDirectory.path}${Platform.pathSeparator}$_settingsFileName',
        );
        await file.writeAsString(jsonEncode(settings.toMap()), flush: true);
        return;
      } on Object catch (error) {
        throw UserSettingsStoreException('Could not save settings.', error);
      }
    }
    try {
      await _channel.invokeMethod<void>('saveSettings', settings.toMap());
    } on PlatformException catch (error) {
      throw UserSettingsStoreException('Could not save settings.', error);
    } on MissingPluginException catch (error) {
      throw UserSettingsStoreException(
        'Settings storage is unavailable.',
        error,
      );
    }
  }

  Future<void> deleteSettings() async {
    _checkWindowsDirectory();
    final localDirectory = _localDirectory;
    if (localDirectory != null) {
      final file = File(
        '${localDirectory.path}${Platform.pathSeparator}$_settingsFileName',
      );
      try {
        if (await file.exists()) await file.delete();
        return;
      } on Object catch (error) {
        throw UserSettingsStoreException('Could not delete settings.', error);
      }
    }
    try {
      await _channel.invokeMethod<void>('deleteSettings');
    } on PlatformException catch (error) {
      throw UserSettingsStoreException('Could not delete settings.', error);
    } on MissingPluginException catch (error) {
      throw UserSettingsStoreException(
        'Settings storage is unavailable.',
        error,
      );
    }
  }
}
