import 'dart:async';

import 'package:flutter/foundation.dart';

import '../content/privacy_policy.dart';
import '../models/collector_models.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_history.dart';
import '../models/usage_report.dart';
import 'consent_store.dart';
import 'streak_store.dart';
import 'usage_history_store.dart';

/// Owns everything about usage data: consent, the platform collector, the
/// local history and the streak ledger. Screens only read reports from here.
class UsageController extends ChangeNotifier {
  UsageController({
    required this._collector,
    required this._history,
    required this._streak,
    required this._consent,
    DateTime Function()? clock,
    this.pollInterval = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now;

  final UsageCollector _collector;
  final UsageHistoryStore _history;
  final StreakStore _streak;
  final ConsentStore _consent;
  final DateTime Function() _clock;
  final Duration pollInterval;

  final _ingestor = EventIngestor();
  Timer? _poll;
  DateTime? _runStart;
  Future<void> _queue = Future<void>.value();
  HistoryIndex? _index;
  bool _disposed = false;

  CollectorStatus? _status;
  String? _lastError;
  DateTime? _lastSync;
  int _goalMinutes = 360;
  bool _loaded = false;

  CollectorStatus? get status => _status;
  String? get lastError => _lastError;
  DateTime? get lastSync => _lastSync;
  bool get isLoaded => _loaded;
  PrivacyChoices get choices => _consent.choices;
  String? get consentIssue => _consent.issue;
  String? get historyIssue => _history.issue;
  String? get streakIssue => _streak.issue;
  List<StreakDay> get streakDays => _streak.days;
  bool get isCollecting => _status?.collecting ?? false;

  /// Collection stopped by hand (tray or Settings) until resumed or restart.
  bool get isPaused => _paused;
  bool _paused = false;
  bool get historyIsEmpty => _history.isEmpty;

  bool get collectorAvailable {
    final lifecycle = _status?.lifecycle;
    return lifecycle != null &&
        lifecycle != CollectorLifecycle.unavailable &&
        lifecycle != CollectorLifecycle.failed;
  }

  /// REAL only when the user chose it, consented and the collector exists.
  /// Everything else is DEMO, which is always labelled and never recorded.
  UsageDataMode get mode => choices.wantsCollection && collectorAvailable
      ? UsageDataMode.real
      : UsageDataMode.demo;

  HistoryIndex get index => _index ??= HistoryIndex(
    sessions: _history.sessions,
    launches: _history.launches,
    intervals: _history.intervals,
  );

  set goalMinutes(int value) {
    if (value <= 0 || value == _goalMinutes) return;
    _goalMinutes = value;
    _notify();
  }

  Future<void> load() async {
    await _consent.load();
    await _history.load();
    await _streak.load();
    _status = await _collector.getStatus();
    _loaded = true;
    _index = null;
    _notify();
    if (choices.wantsCollection) await startCollection();
  }

  Future<void> refreshStatus() async {
    _status = await _collector.getStatus();
    _notify();
  }

  // ---- Consent and mode -------------------------------------------------

  Future<void> setConsent(bool granted) async {
    await _consent.save(
      choices.copyWith(
        collectionConsent: granted,
        consentChangedAt: _clock(),
        policyVersion: privacyPolicyVersion,
        preferRealData: granted ? choices.preferRealData : false,
      ),
    );
    if (granted && choices.preferRealData) {
      await startCollection();
    } else if (!granted) {
      await stopCollection();
    }
    _notify();
  }

  /// Stops collecting until [resumeCollection] or the next app start.
  /// Consent and the REAL choice stay as they are.
  Future<void> pauseCollection() async {
    _paused = true;
    await stopCollection();
  }

  Future<void> resumeCollection() async {
    _paused = false;
    if (choices.wantsCollection) await startCollection();
    _notify();
  }

  Future<void> setLocalAi({required bool enabled, String? model}) async {
    await _consent.save(
      choices.copyWith(localAiEnabled: enabled, localAiModel: model),
    );
    _notify();
  }

  Future<void> setBackgroundCollection(bool enabled) async {
    await _consent.save(choices.copyWith(backgroundCollection: enabled));
    _notify();
  }

  Future<void> setPreferRealData(bool real) async {
    await _consent.save(choices.copyWith(preferRealData: real));
    if (choices.wantsCollection) {
      await startCollection();
    } else {
      await stopCollection();
    }
    _notify();
  }

  Future<void> completeOnboarding({
    required bool consent,
    required bool preferReal,
  }) async {
    await _consent.save(
      choices.copyWith(
        collectionConsent: consent,
        consentChangedAt: _clock(),
        policyVersion: privacyPolicyVersion,
        preferRealData: consent && preferReal,
        onboardingCompleted: true,
      ),
    );
    if (choices.wantsCollection) await startCollection();
    _notify();
  }

  // ---- Collection -------------------------------------------------------

  Future<void> startCollection() => _serial(() async {
    if (!choices.collectionConsent) {
      _lastError = 'Сбор не запускается без согласия.';
      return;
    }
    if (_paused) return;
    _status = await _collector.getStatus();
    if (!collectorAvailable) return;
    try {
      await _collector.start(userConsent: true);
      _runStart ??= _clock();
      _lastError = null;
      _poll ??= Timer.periodic(pollInterval, (_) => unawaited(sync()));
    } on Object catch (error) {
      _lastError = 'Не удалось запустить сбор: $error';
    }
    _status = await _collector.getStatus();
  });

  Future<void> stopCollection() => _serial(() async {
    _poll?.cancel();
    _poll = null;
    if (_runStart == null && !isCollecting) return;
    try {
      await _collector.stop();
      await _drain();
      await _history.add(_ingestor.close(_clock()));
    } on Object catch (error) {
      _lastError = 'Сбор остановлен с ошибкой: $error';
    }
    _runStart = null;
    _index = null;
    _status = await _collector.getStatus();
  });

  /// Drains collector events into history and records finished streak days.
  Future<void> sync() => _serial(() async {
    if (_runStart == null) return;
    try {
      await _drain();
      _lastError = null;
    } on Object catch (error) {
      _lastError = 'Не удалось сохранить новые данные: $error';
    }
    _status = await _collector.getStatus();
  });

  Future<void> _drain() async {
    final snapshot = await _collector.drainEvents();
    await _history.add(_ingestor.ingest(snapshot));
    final runStart = _runStart;
    if (runStart != null) {
      await _history.extendCoverage(runStart, snapshot.capturedAt);
    }
    _index = null;
    _lastSync = _clock();
    if (mode == UsageDataMode.real && _streak.isAvailable) {
      await _streak.recordCompletedDays(
        index.completedStreakDays(
          today: LocalDay.fromDateTime(_clock()),
          goalMinutes: _goalMinutes,
        ),
        today: LocalDay.fromDateTime(_clock()),
      );
    }
  }

  /// Saves what was collected and stops, e.g. before the app quits.
  Future<void> shutdown() async {
    if (_runStart != null) await stopCollection();
  }

  // ---- Reports ----------------------------------------------------------

  UsageReport report({required LocalDay today, int periodDays = 7}) =>
      switch (mode) {
        UsageDataMode.demo => buildDemoReport(
          demoUsage.withTarget(_goalMinutes),
        ),
        UsageDataMode.real => buildRealReport(
          index: index,
          today: today,
          goalMinutes: _goalMinutes,
          periodDays: periodDays,
        ),
      };

  StreakSummary streakSummary({required LocalDay today}) => switch (mode) {
    UsageDataMode.demo => demoStreakPreview(
      demoUsage.withTarget(_goalMinutes),
      today: today,
    ),
    UsageDataMode.real => StreakCalculator.summarize(
      days: _streak.days,
      today: today,
      goalMinutes: _goalMinutes,
      todayMinutes: index.day(today).activeMinutes,
    ),
  };

  // ---- Data lifecycle ---------------------------------------------------

  Map<String, Object?> exportData() => {
    'privacyChoices': choices.toMap(),
    'usageHistory': _history.exportData(),
    'streakHistory': _streak.days.map((d) => d.toMap()).toList(),
  };

  Future<void> clearUsageHistory() async {
    await stopCollection();
    await _history.clear();
    _index = null;
    _notify();
  }

  Future<void> clearStreak() async {
    await _streak.clear();
    _notify();
  }

  Future<void> clearConsent() async {
    await stopCollection();
    await _consent.clear();
    _notify();
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((_) {});
    return next.whenComplete(_notify);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }
}
