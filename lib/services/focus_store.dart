import 'dart:convert';
import 'dart:io';

import '../models/focus_session.dart';
import '../models/streak.dart';

/// Local history of focus sessions and the apps marked as "work".
///
/// Lives in `focus.json` in the app-data folder, is never sent anywhere and
/// is removed by [clear]. Without a folder ([FocusStore.unavailable]) the
/// history is kept in memory only. If the file cannot be read it is left
/// untouched: new sessions stay in memory and nothing is written until
/// [clear].
class FocusStore {
  FocusStore({Directory? directory}) : this._(directory);

  FocusStore._(this._directory);

  FocusStore.unavailable() : this._(null);

  final Directory? _directory;
  final Map<String, FocusSession> _sessions = {};
  final Set<String> _workApps = {};
  String? _issue;
  bool _loaded = false;

  static const fileName = 'focus.json';

  /// `true` when changes are written to disk.
  bool get isAvailable => _directory != null && _issue == null;
  bool get isLoaded => _loaded;
  String? get issue => _issue;

  /// Sessions, newest first.
  List<FocusSession> get sessions => List.unmodifiable(
    _sessions.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt)),
  );

  Set<String> get workAppIds => Set.unmodifiable(_workApps);

  File? get _file {
    final directory = _directory;
    return directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  Future<void> load() async {
    _issue = null;
    _sessions.clear();
    _workApps.clear();
    final file = _file;
    try {
      if (file == null || !await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported focus data format.');
      }
      final records = decoded['sessions'];
      final apps = decoded['workApps'];
      if (records is! List || (apps != null && apps is! List)) {
        throw const FormatException('Invalid focus data.');
      }
      for (final record in records) {
        if (record is! Map<Object?, Object?>) {
          throw const FormatException('Invalid focus data.');
        }
        final session = FocusSession.fromMap(record);
        _sessions.putIfAbsent(session.id, () => session);
      }
      for (final app in (apps as List?) ?? const []) {
        if (app is String && app.isNotEmpty) _workApps.add(app);
      }
    } on Object {
      _sessions.clear();
      _workApps.clear();
      _issue = 'Не удалось прочитать историю фокуса; запись отключена.';
    } finally {
      _loaded = true;
    }
  }

  /// Adds a finished session. A session with the same id is kept as it was.
  Future<void> add(FocusSession session) async {
    if (_sessions.containsKey(session.id)) return;
    final next = Map<String, FocusSession>.of(_sessions)
      ..[session.id] = session;
    await _commit(next.values, _workApps);
    _sessions
      ..clear()
      ..addAll(next);
  }

  Future<void> setWorkApps(Iterable<String> appIds) async {
    final next = appIds.where((a) => a.isNotEmpty).toSet();
    await _commit(_sessions.values, next);
    _workApps
      ..clear()
      ..addAll(next);
  }

  /// Focused seconds of sessions that started on local days `[from, to]`.
  int totalSeconds({required LocalDay from, required LocalDay to}) => _sessions
      .values
      .where((s) {
        final day = LocalDay.fromDateTime(s.startedAt);
        return !day.isBefore(from) && !to.isBefore(day);
      })
      .fold(0, (sum, s) => sum + s.focusedSeconds);

  /// Focused seconds over the last [days] local days, today included.
  int totalForLastDays(int days, {required LocalDay today}) =>
      totalSeconds(from: today.addDays(-(days - 1)), to: today);

  Future<void> clear() async {
    final file = _file;
    if (file != null) {
      if (await file.exists()) await file.delete();
      final staging = File('${file.path}.new');
      if (await staging.exists()) await staging.delete();
    }
    _sessions.clear();
    _workApps.clear();
    _issue = null;
  }

  Future<void> _commit(
    Iterable<FocusSession> sessions,
    Set<String> workApps,
  ) async {
    final directory = _directory;
    // Memory only: no folder, or the file on disk could not be read and must
    // not be overwritten.
    if (directory == null || _issue != null) return;
    try {
      await directory.create(recursive: true);
      final file = _file!;
      final staging = File('${file.path}.new');
      final sorted = sessions.toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      final content = const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'sessions': sorted.map((s) => s.toMap()).toList(),
        'workApps': (workApps.toList()..sort()),
      });
      await staging.writeAsString(content, flush: true);
      await staging.rename(file.path);
    } on Object {
      _issue = 'Не удалось сохранить историю фокуса; запись отключена.';
      rethrow;
    }
  }
}
