import 'dart:convert';
import 'dart:io';

import 'user_settings_store.dart';

class LocalFeedback {
  const LocalFeedback({
    required this.message,
    required this.createdAt,
    this.rating,
  });

  final String message;
  final DateTime createdAt;
  final int? rating;

  Map<String, Object?> toMap() => {
    'message': message,
    'createdAt': createdAt.toIso8601String(),
    if (rating != null) 'rating': rating,
  };

  factory LocalFeedback.fromMap(Map<Object?, Object?> map) {
    final message = map['message'];
    final date = map['createdAt'];
    final rawRating = map['rating'];
    if (message is! String || date is! String) {
      throw const FormatException('Invalid local feedback record.');
    }
    final createdAt = DateTime.tryParse(date);
    if (createdAt == null || (rawRating != null && rawRating is! int)) {
      throw const FormatException('Invalid local feedback record.');
    }
    final rating = rawRating as int?;
    if (rating != null && (rating < 1 || rating > 5)) {
      throw const FormatException('Invalid local feedback rating.');
    }
    return LocalFeedback(
      message: message,
      createdAt: createdAt,
      rating: rating,
    );
  }
}

class PrivacyStorageUnavailable implements Exception {
  const PrivacyStorageUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

enum LocalDataDeletionResult {
  complete,
  settingsDeletionFailed,
  feedbackDeletionFailedAfterSettings,
  streakDeletionFailedAfterFeedback,
  usageDataDeletionFailed,
}

/// Stores feedback in the app's durable private data folder and exports to a
/// user documents folder only on platforms where that path is supported.
class PrivacyDataStore {
  factory PrivacyDataStore({
    Directory? appDataDirectory,
    Directory? documentsDirectory,
    Directory? legacyAppDataDirectory,
  }) {
    final paths = _resolvePlatformPaths();
    return PrivacyDataStore._(
      appDataDirectory: appDataDirectory ?? paths.appDataDirectory,
      documentsDirectory: documentsDirectory ?? paths.documentsDirectory,
      appDataUnavailableReason: paths.appDataUnavailableReason,
      exportUnavailableReason: paths.exportUnavailableReason,
      legacyAppDataDirectory: appDataDirectory != null
          ? legacyAppDataDirectory
          : paths.legacyAppDataDirectory,
    );
  }

  factory PrivacyDataStore.forWindowsEnvironment(
    Map<String, String> environment,
  ) {
    final paths = _resolveWindowsPaths(environment);
    return PrivacyDataStore._(
      appDataDirectory: paths.appDataDirectory,
      documentsDirectory: paths.documentsDirectory,
      appDataUnavailableReason: paths.appDataUnavailableReason,
      exportUnavailableReason: paths.exportUnavailableReason,
    );
  }

  PrivacyDataStore._({
    required this._appDataDirectory,
    required this._documentsDirectory,
    required this._appDataUnavailableReason,
    required this._exportUnavailableReason,
    this._legacyAppDataDirectory,
  });

  /// Where earlier builds stored data by mistake; moved once on load.
  final Directory? _legacyAppDataDirectory;

  PrivacyDataStore.unavailable({
    String feedbackReason = 'Локальное хранилище недоступно на этой платформе.',
    String exportReason = 'Экспорт недоступен в этой сборке.',
  }) : this._(
         appDataDirectory: null,
         documentsDirectory: null,
         appDataUnavailableReason: feedbackReason,
         exportUnavailableReason: exportReason,
       );

  final Directory? _appDataDirectory;
  final Directory? _documentsDirectory;
  final String? _appDataUnavailableReason;
  final String? _exportUnavailableReason;
  final List<LocalFeedback> _feedback = [];
  bool _loaded = false;
  String? _storageIssue;

  static const _fileName = 'feedback.json';
  static const _exportFilePrefix = 'reboot-privacy-export';

  List<LocalFeedback> get feedback => List.unmodifiable(_feedback);
  bool get isLoaded => _loaded;
  bool get canStoreFeedback =>
      _appDataDirectory != null && _storageIssue == null;
  bool get canExport =>
      _documentsDirectory != null && _loaded && _storageIssue == null;
  String? get storageIssue => _storageIssue ?? _appDataUnavailableReason;
  String get exportUnavailableReason =>
      _exportUnavailableReason ?? 'Экспорт недоступен в этой сборке.';
  String? get appDataDirectoryPath => _appDataDirectory?.path;
  String? get documentsDirectoryPath => _documentsDirectory?.path;

  static _PrivacyStoragePaths _resolvePlatformPaths() {
    if (Platform.isWindows) return _resolveWindowsPaths(Platform.environment);
    final home = Platform.environment['HOME'];
    if (home == null || !home.startsWith(Platform.pathSeparator)) {
      return const _PrivacyStoragePaths(
        appDataDirectory: null,
        documentsDirectory: null,
        appDataUnavailableReason:
            'Не удалось определить домашнюю папку приложения.',
        exportUnavailableReason: 'Не удалось определить папку документов.',
      );
    }
    if (Platform.isMacOS) {
      // Inside the App Sandbox HOME already is the container
      // (~/Library/Containers/<bundle id>/Data). Earlier builds appended the
      // container path again and wrote to a nested folder; that folder is
      // migrated by [loadFeedback].
      const containerSuffix =
          'Library/Containers/com.reboot.app.rebootApp/Data';
      final sandboxed = home.endsWith(containerSuffix);
      final container = sandboxed ? home : _join([home, containerSuffix]);
      return _PrivacyStoragePaths(
        appDataDirectory: Directory(
          _join([container, 'Library', 'Application Support']),
        ),
        legacyAppDataDirectory: sandboxed
            ? Directory(
                _join([
                  home,
                  containerSuffix,
                  'Library',
                  'Application Support',
                ]),
              )
            : null,
        documentsDirectory: null,
        appDataUnavailableReason: null,
        exportUnavailableReason: 'Для доступа к папке документов macOS нужен системный диалог сохранения.',
      );
    }
    if (Platform.isIOS) {
      return _PrivacyStoragePaths(
        appDataDirectory: Directory(
          _join([home, 'Library', 'Application Support', 'REBOOT']),
        ),
        documentsDirectory: null,
        appDataUnavailableReason: null,
        exportUnavailableReason: 'Экспорт в Files недоступен без системной настройки общего доступа к файлам.',
      );
    }
    if (Platform.isAndroid) {
      return const _PrivacyStoragePaths(
        appDataDirectory: null,
        documentsDirectory: null,
        appDataUnavailableReason: 'Отзывы недоступны на Android: в этой сборке нет безопасного app-data пути.',
        exportUnavailableReason:
            'Экспорт недоступен на Android без системного выбора файла.',
      );
    }
    return const _PrivacyStoragePaths(
      appDataDirectory: null,
      documentsDirectory: null,
      appDataUnavailableReason:
          'Локальное хранилище недоступно на этой платформе.',
      exportUnavailableReason: 'Экспорт недоступен на этой платформе.',
    );
  }

  static _PrivacyStoragePaths _resolveWindowsPaths(
    Map<String, String> environment,
  ) {
    final localAppData = environment['LOCALAPPDATA']?.trim();
    final userProfile = environment['USERPROFILE']?.trim();
    final validLocal = localAppData != null && _isWindowsAbsolute(localAppData);
    final validProfile = userProfile != null && _isWindowsAbsolute(userProfile);
    return _PrivacyStoragePaths(
      appDataDirectory: validLocal
          ? Directory(_windowsJoin(localAppData, 'REBOOT'))
          : null,
      documentsDirectory: validProfile
          ? Directory(_windowsJoin(userProfile, r'Documents\REBOOT'))
          : null,
      appDataUnavailableReason: validLocal ? null : 'Переменная LOCALAPPDATA недоступна; локальные отзывы нельзя сохранить.',
      exportUnavailableReason: validProfile
          ? null
          : 'Переменная USERPROFILE недоступна; экспорт файла недоступен.',
    );
  }

  static String _windowsJoin(String root, String child) {
    final normalizedRoot = _normalizeWindowsPath(root)
        .replaceAll(RegExp(r'\\+$'), '');
    final normalizedChild = _normalizeWindowsPath(child)
        .replaceAll(RegExp(r'^\\+'), '');
    return '$normalizedRoot\\$normalizedChild';
  }

  static String _normalizeWindowsPath(String path) {
    final replaced = path.replaceAll('/', r'\');
    final isUnc = replaced.startsWith(r'\\');
    final collapsed = replaced.replaceAll(RegExp(r'\\{2,}'), r'\');
    return isUnc ? r'\' + collapsed : collapsed;
  }

  static bool _isWindowsAbsolute(String path) =>
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');

  static String _join(List<String> parts) => parts.join(Platform.pathSeparator);

  /// Moves files from the legacy nested folder into the app-data folder.
  /// Nothing is overwritten: a file that already exists at the new place
  /// stays, and the legacy copy is left where it is.
  Future<void> migrateLegacyData() async {
    final legacy = _legacyAppDataDirectory;
    final target = _appDataDirectory;
    if (legacy == null || target == null || legacy.path == target.path) return;
    try {
      if (!await legacy.exists()) return;
      await target.create(recursive: true);
      await for (final entity in legacy.list()) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final destination = _join([target.path, name]);
        if (await FileSystemEntity.type(destination) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        await entity.rename(destination);
      }
    } on Object {
      // Migration is best effort; the old copy is still in place.
    }
  }

  Future<void> loadFeedback() async {
    await migrateLegacyData();
    _loaded = false;
    _storageIssue = null;
    final directory = _appDataDirectory;
    if (directory == null) {
      _storageIssue = _appDataUnavailableReason;
      _loaded = true;
      return;
    }
    try {
      final file = File(_join([directory.path, _fileName]));
      if (!await file.exists()) {
        _feedback.clear();
      } else {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
          throw const FormatException('Unsupported feedback data format.');
        }
        final records = decoded['feedback'];
        if (records is! List) {
          throw const FormatException('Invalid feedback data.');
        }
        final loaded = records.map((record) {
          if (record is! Map<Object?, Object?>) {
            throw const FormatException('Invalid feedback data.');
          }
          return LocalFeedback.fromMap(record);
        }).toList();
        _feedback
          ..clear()
          ..addAll(loaded);
      }
    } on Object {
      _storageIssue =
          'Не удалось прочитать локальные отзывы; сохранение отключено.';
    } finally {
      _loaded = true;
    }
  }

  Future<void> saveFeedback(LocalFeedback feedback) async {
    _ensureReadyForWrite();
    final next = [..._feedback, feedback];
    try {
      await _writeFeedback(next);
    } on Object {
      _storageIssue =
          'Не удалось сохранить локальный отзыв; сохранение отключено.';
      rethrow;
    }
    _feedback
      ..clear()
      ..addAll(next);
  }

  Future<void> clearFeedback() async {
    final directory = _appDataDirectory;
    if (directory != null) {
      final file = File(_join([directory.path, _fileName]));
      if (await file.exists()) await file.delete();
      final staging = File('${file.path}.new');
      if (await staging.exists()) await staging.delete();
    }
    _feedback.clear();
    _storageIssue = null;
  }

  /// The user's own data in one readable JSON document: settings, feedback
  /// and, when given, usage history, streak days and privacy choices.
  /// Demo fixtures are never included.
  String readableExport(
    UserSettings settings, {
    Map<String, Object?> usageData = const {},
  }) {
    final payload = {
      'exportType': 'REBOOT local data export',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'settings': settings.toMap(),
      'feedback': _feedback.map((item) => item.toMap()).toList(),
      ...usageData,
      if (!usageData.containsKey('usageHistory'))
        'usageHistory': 'No usage history stored',
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  String suggestedExportName() =>
      '$_exportFilePrefix-${DateTime.now().toUtc().microsecondsSinceEpoch}.json';

  bool get canExportFile => canExport;

  Future<File> exportToDocuments(
    UserSettings settings, {
    Map<String, Object?> usageData = const {},
  }) => writeExportFile(
    suggestedExportName(),
    readableExport(settings, usageData: usageData),
  );

  /// Writes an export into the documents folder (Windows).
  Future<File> writeExportFile(String name, String content) async {
    if (!_loaded || _storageIssue != null) {
      throw PrivacyStorageUnavailable(
        _storageIssue ?? 'Локальные отзывы ещё не загружены.',
      );
    }
    final directory = _documentsDirectory;
    if (directory == null) {
      throw PrivacyStorageUnavailable(exportUnavailableReason);
    }
    await directory.create(recursive: true);
    final file = File(_join([directory.path, name]));
    return file.writeAsString(content, flush: true);
  }

  void _ensureReadyForWrite() {
    if (!_loaded) {
      throw const PrivacyStorageUnavailable(
        'Локальное хранилище ещё не загружено.',
      );
    }
    if (_storageIssue != null || _appDataDirectory == null) {
      throw PrivacyStorageUnavailable(
        _storageIssue ?? 'Локальное хранилище недоступно на этой платформе.',
      );
    }
  }

  Future<void> _writeFeedback(List<LocalFeedback> records) async {
    final directory = _appDataDirectory!;
    await directory.create(recursive: true);
    final file = File(_join([directory.path, _fileName]));
    final staging = File('${file.path}.new');
    final content = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'feedback': records.map((item) => item.toMap()).toList(),
    });
    await staging.writeAsString(content, flush: true);
    await staging.rename(file.path);
  }
}

class _PrivacyStoragePaths {
  const _PrivacyStoragePaths({
    required this.appDataDirectory,
    required this.documentsDirectory,
    required this.appDataUnavailableReason,
    required this.exportUnavailableReason,
    this.legacyAppDataDirectory,
  });

  final Directory? legacyAppDataDirectory;
  final Directory? appDataDirectory;
  final Directory? documentsDirectory;
  final String? appDataUnavailableReason;
  final String? exportUnavailableReason;
}
