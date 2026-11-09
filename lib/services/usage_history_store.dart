import 'dart:convert';
import 'dart:io';

import '../models/streak.dart';
import '../models/usage_history.dart';

/// Local usage history: one JSON file per local day under `usage-history/`
/// in the app-data folder. Nothing here leaves the device.
///
/// Records older than [retentionDays] are deleted automatically.
class UsageHistoryStore {
  UsageHistoryStore({
    Directory? directory,
    int retentionDays = 90,
    DateTime Function()? clock,
  }) : this._(directory, retentionDays, clock ?? DateTime.now);

  UsageHistoryStore.unavailable() : this._(null, 90, DateTime.now);

  UsageHistoryStore._(this._root, this.retentionDays, this._clock);

  static const folderName = 'usage-history';

  final Directory? _root;
  final int retentionDays;
  final DateTime Function() _clock;
  final Map<LocalDay, _DayFile> _files = {};
  String? _issue;

  bool get isAvailable => _root != null && _issue == null;
  String? get issue => _issue;

  Directory? get _folder {
    final root = _root;
    return root == null
        ? null
        : Directory('${root.path}${Platform.pathSeparator}$folderName');
  }

  List<AppSession> get sessions =>
      _collect((f) => f.sessions)..sort((a, b) => a.start.compareTo(b.start));
  List<AppLaunch> get launches =>
      _collect((f) => f.launches)..sort((a, b) => a.at.compareTo(b.at));
  List<TimeInterval> get intervals =>
      _collect((f) => f.intervals)..sort((a, b) => a.start.compareTo(b.start));

  bool get isEmpty => _files.values.every((f) => f.isEmpty);

  List<T> _collect<T>(List<T> Function(_DayFile) pick) => [
    for (final file in _files.values) ...pick(file),
  ];

  LocalDay get _oldestKept =>
      LocalDay.fromDateTime(_clock()).addDays(-(retentionDays - 1));

  Future<void> load() async {
    _issue = null;
    _files.clear();
    final folder = _folder;
    if (folder == null || !await folder.exists()) return;
    try {
      await for (final entity in folder.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final name = entity.uri.pathSegments.last;
        final day = LocalDay.tryParse(name.substring(0, name.length - 5));
        if (day == null) continue;
        if (day.isBefore(_oldestKept)) {
          await entity.delete();
          continue;
        }
        _files[day] = _DayFile.decode(await entity.readAsString());
      }
    } on Object {
      _files.clear();
      _issue =
          'Не удалось прочитать историю использования; запись приостановлена.';
    }
  }

  /// Adds a drained batch. Exact duplicates are ignored and a checkpoint piece
  /// that continues the previous session of the same app is merged into it.
  Future<void> add(HistoryBatch batch) async {
    if (!isAvailable || batch.isEmpty) return;
    final touched = <LocalDay>{};
    for (final session in batch.sessions) {
      final merged = _mergeIntoExisting(session);
      if (merged != null) {
        touched.add(merged);
        continue;
      }
      final day = LocalDay.fromDateTime(session.start);
      final file = _files.putIfAbsent(day, _DayFile.new);
      if (file.sessions.any((s) => _overlapsSameApp(s, session))) continue;
      file.sessions.add(session);
      touched.add(day);
    }
    for (final launch in batch.launches) {
      final day = LocalDay.fromDateTime(launch.at);
      final file = _files.putIfAbsent(day, _DayFile.new);
      if (file.launches.any((l) => l.key == launch.key)) continue;
      file.launches.add(launch);
      touched.add(day);
    }
    for (final interval in batch.intervals) {
      final day = LocalDay.fromDateTime(interval.start);
      final file = _files.putIfAbsent(day, _DayFile.new);
      if (file.intervals.any((i) => i.key == interval.key)) continue;
      file.intervals.add(interval);
      touched.add(day);
    }
    for (final (start, end) in batch.inactiveWindows) {
      touched.addAll(_cutOut(start, end));
    }
    await _writeDays(touched);
  }

  /// Removes active time inside `[start, end)` from stored sessions,
  /// splitting a session that spans the window.
  Set<LocalDay> _cutOut(DateTime start, DateTime end) {
    final touched = <LocalDay>{};
    if (!end.isAfter(start)) return touched;
    for (final entry in _files.entries) {
      final list = entry.value.sessions;
      for (var i = list.length - 1; i >= 0; i--) {
        final s = list[i];
        if (!s.start.isBefore(end) || !start.isBefore(s.end)) continue;
        list.removeAt(i);
        touched.add(entry.key);
        if (s.start.isBefore(start)) {
          list.add(
            AppSession(
              appId: s.appId,
              appName: s.appName,
              start: s.start,
              end: start,
            ),
          );
        }
        if (end.isBefore(s.end)) {
          final piece = AppSession(
            appId: s.appId,
            appName: s.appName,
            start: end,
            end: s.end,
          );
          _files
              .putIfAbsent(LocalDay.fromDateTime(end), _DayFile.new)
              .sessions
              .add(piece);
          touched.add(LocalDay.fromDateTime(end));
        }
      }
    }
    return touched;
  }

  /// Records that the collector run started at [runStart] is still alive at
  /// [now]. One coverage interval per run, extended on every poll.
  Future<void> extendCoverage(DateTime runStart, DateTime now) async {
    if (!isAvailable || !now.isAfter(runStart)) return;
    final day = LocalDay.fromDateTime(runStart);
    final file = _files.putIfAbsent(day, _DayFile.new);
    file.intervals.removeWhere(
      (i) =>
          i.kind == IntervalKind.coverage &&
          i.start.isAtSameMomentAs(runStart.toUtc()),
    );
    file.intervals.add(
      TimeInterval(kind: IntervalKind.coverage, start: runStart, end: now),
    );
    await _writeDays({day});
  }

  Future<void> clear() async {
    final folder = _folder;
    if (folder != null && await folder.exists()) {
      await folder.delete(recursive: true);
    }
    _files.clear();
    _issue = null;
  }

  /// Everything stored, for the user's own export.
  Map<String, Object> exportData() => {
    'retentionDays': retentionDays,
    'sessions': sessions.map((s) => s.toMap()).toList(),
    'launches': launches.map((l) => l.toMap()).toList(),
    'intervals': intervals.map((i) => i.toMap()).toList(),
  };

  static bool _overlapsSameApp(AppSession a, AppSession b) =>
      a.appId == b.appId && a.start.isBefore(b.end) && b.start.isBefore(a.end);

  LocalDay? _mergeIntoExisting(AppSession session) {
    final startDay = LocalDay.fromDateTime(session.start);
    for (final day in [startDay, startDay.addDays(-1)]) {
      final file = _files[day];
      if (file == null) continue;
      for (var i = file.sessions.length - 1; i >= 0; i--) {
        final existing = file.sessions[i];
        if (existing.appId != session.appId) continue;
        final gap = session.start.difference(existing.end).inMilliseconds.abs();
        if (gap <= 1000 && session.end.isAfter(existing.end)) {
          file.sessions[i] = existing.copyWith(end: session.end);
          return day;
        }
      }
    }
    return null;
  }

  Future<void> _writeDays(Set<LocalDay> days) async {
    if (days.isEmpty) return;
    final folder = _folder!;
    try {
      await folder.create(recursive: true);
      for (final day in days) {
        final file = File(
          '${folder.path}${Platform.pathSeparator}${day.key}.json',
        );
        final staging = File('${file.path}.new');
        await staging.writeAsString(_files[day]!.encode(), flush: true);
        await staging.rename(file.path);
      }
      for (final day in _files.keys.toList()) {
        if (!day.isBefore(_oldestKept)) continue;
        _files.remove(day);
        final old = File(
          '${folder.path}${Platform.pathSeparator}${day.key}.json',
        );
        if (await old.exists()) await old.delete();
      }
    } on Object {
      _issue =
          'Не удалось сохранить историю использования; запись приостановлена.';
      rethrow;
    }
  }
}

class _DayFile {
  _DayFile();

  final sessions = <AppSession>[];
  final launches = <AppLaunch>[];
  final intervals = <TimeInterval>[];

  bool get isEmpty => sessions.isEmpty && launches.isEmpty && intervals.isEmpty;

  factory _DayFile.decode(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      throw const FormatException('Unsupported usage history format.');
    }
    List<Map<Object?, Object?>> list(String key) {
      final raw = decoded[key];
      if (raw is! List) throw const FormatException('Invalid usage history.');
      return [
        for (final item in raw)
          if (item is Map<Object?, Object?>)
            item
          else
            throw const FormatException('Invalid usage history.'),
      ];
    }

    return _DayFile()
      ..sessions.addAll(list('sessions').map(AppSession.fromMap))
      ..launches.addAll(list('launches').map(AppLaunch.fromMap))
      ..intervals.addAll(list('intervals').map(TimeInterval.fromMap));
  }

  String encode() => const JsonEncoder.withIndent(' ').convert({
    'version': 1,
    'sessions': sessions.map((s) => s.toMap()).toList(),
    'launches': launches.map((l) => l.toMap()).toList(),
    'intervals': intervals.map((i) => i.toMap()).toList(),
  });
}
