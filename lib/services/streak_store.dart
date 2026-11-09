import 'dart:convert';
import 'dart:io';

import '../models/streak.dart';

/// Local ledger of completed days measured by the usage collector.
///
/// Lives next to `feedback.json` in the app-data folder. It never stores demo
/// data, is never sent anywhere, and is removed by "Delete local data".
class StreakStore {
  StreakStore({Directory? directory}) : this._(directory);

  StreakStore._(this._directory);

  StreakStore.unavailable() : this._(null);

  final Directory? _directory;
  final Map<LocalDay, StreakDay> _days = {};
  String? _issue;

  static const fileName = 'streak.json';

  bool get isAvailable => _directory != null && _issue == null;
  String? get issue => _issue;

  /// Recorded days, oldest first.
  List<StreakDay> get days => List.unmodifiable(
    _days.values.toList()..sort((a, b) => a.day.compareTo(b.day)),
  );

  File? get _file {
    final directory = _directory;
    return directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  Future<void> load() async {
    _issue = null;
    _days.clear();
    final file = _file;
    if (file == null || !await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported streak data format.');
      }
      final records = decoded['days'];
      if (records is! List) throw const FormatException('Invalid streak data.');
      for (final record in records) {
        if (record is! Map<Object?, Object?>) {
          throw const FormatException('Invalid streak data.');
        }
        final day = StreakDay.fromMap(record);
        _days.putIfAbsent(day.day, () => day);
      }
    } on Object {
      _days.clear();
      _issue = 'Не удалось прочитать историю серии; запись отключена.';
    }
  }

  /// Records finished days from collector data and returns how many were new.
  ///
  /// Days dated [today] or later are skipped because they are not finished.
  /// A day that is already recorded is kept as it was, so restarts, repeated
  /// syncs or a later time zone change cannot count the same day twice.
  Future<int> recordCompletedDays(
    Iterable<StreakDay> candidates, {
    required LocalDay today,
  }) async {
    if (!isAvailable) return 0;
    final next = Map<LocalDay, StreakDay>.of(_days);
    var added = 0;
    for (final item in candidates) {
      if (!item.day.isBefore(today) || next.containsKey(item.day)) continue;
      next[item.day] = item;
      added++;
    }
    if (added == 0) return 0;
    try {
      await _write(next.values);
    } on Object {
      _issue = 'Не удалось сохранить историю серии; запись отключена.';
      rethrow;
    }
    _days
      ..clear()
      ..addAll(next);
    return added;
  }

  Future<void> clear() async {
    final file = _file;
    if (file != null) {
      if (await file.exists()) await file.delete();
      final staging = File('${file.path}.new');
      if (await staging.exists()) await staging.delete();
    }
    _days.clear();
    _issue = null;
  }

  Future<void> _write(Iterable<StreakDay> records) async {
    final directory = _directory!;
    await directory.create(recursive: true);
    final file = _file!;
    final staging = File('${file.path}.new');
    final sorted = records.toList()..sort((a, b) => a.day.compareTo(b.day));
    final content = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'days': sorted.map((item) => item.toMap()).toList(),
    });
    await staging.writeAsString(content, flush: true);
    await staging.rename(file.path);
  }
}
