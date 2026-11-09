import 'dart:convert';
import 'dart:io';

import '../models/app_goal.dart';

/// Daily per-app goals, stored in `app_goals.json` in the app-data folder.
///
/// Never sent anywhere. Without a folder ([AppGoalStore.unavailable]) goals
/// live in memory only. If the file cannot be read it is left untouched:
/// changes stay in memory and nothing is written until [clear].
class AppGoalStore {
  AppGoalStore({Directory? directory}) : this._(directory);

  AppGoalStore._(this._directory);

  AppGoalStore.unavailable() : this._(null);

  final Directory? _directory;
  final Map<String, AppGoal> _goals = {};
  String? _issue;
  bool _loaded = false;

  static const fileName = 'app_goals.json';

  bool get isAvailable => _directory != null && _issue == null;
  bool get isLoaded => _loaded;
  String? get issue => _issue;

  /// Goals in the order they were created.
  List<AppGoal> get goals => List.unmodifiable(
    _goals.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
  );

  AppGoal? goalFor(String appId) => _goals[appId];

  File? get _file {
    final directory = _directory;
    return directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  Future<void> load() async {
    _issue = null;
    _goals.clear();
    final file = _file;
    try {
      if (file == null || !await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported goals format.');
      }
      final records = decoded['goals'];
      if (records is! List) throw const FormatException('Invalid goals.');
      for (final record in records) {
        if (record is! Map<Object?, Object?>) {
          throw const FormatException('Invalid goals.');
        }
        final goal = AppGoal.fromMap(record);
        _goals.putIfAbsent(goal.appId, () => goal);
      }
    } on Object {
      _goals.clear();
      _issue = 'Не удалось прочитать цели по приложениям; запись отключена.';
    } finally {
      _loaded = true;
    }
  }

  /// Adds a goal; returns `false` if the app already has one.
  Future<bool> add(AppGoal goal) async {
    if (_goals.containsKey(goal.appId)) return false;
    await _apply(Map.of(_goals)..[goal.appId] = goal);
    return true;
  }

  /// Replaces the goal of the same app; returns `false` if there is none.
  Future<bool> update(AppGoal goal) async {
    if (!_goals.containsKey(goal.appId)) return false;
    await _apply(Map.of(_goals)..[goal.appId] = goal);
    return true;
  }

  Future<bool> remove(String appId) async {
    if (!_goals.containsKey(appId)) return false;
    await _apply(Map.of(_goals)..remove(appId));
    return true;
  }

  Future<void> clear() async {
    final file = _file;
    if (file != null) {
      if (await file.exists()) await file.delete();
      final staging = File('${file.path}.new');
      if (await staging.exists()) await staging.delete();
    }
    _goals.clear();
    _issue = null;
  }

  Future<void> _apply(Map<String, AppGoal> next) async {
    await _write(next.values);
    _goals
      ..clear()
      ..addAll(next);
  }

  Future<void> _write(Iterable<AppGoal> goals) async {
    final directory = _directory;
    if (directory == null || _issue != null) return;
    try {
      await directory.create(recursive: true);
      final file = _file!;
      final staging = File('${file.path}.new');
      final sorted = goals.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final content = const JsonEncoder.withIndent(
        '  ',
      ).convert({'version': 1, 'goals': sorted.map((g) => g.toMap()).toList()});
      await staging.writeAsString(content, flush: true);
      await staging.rename(file.path);
    } on Object {
      _issue = 'Не удалось сохранить цели по приложениям; запись отключена.';
      rethrow;
    }
  }
}
