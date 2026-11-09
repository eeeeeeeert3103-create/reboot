import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import 'models/collector_models.dart';
import 'models/streak.dart';
import 'models/app_goal.dart';
import 'models/usage_data.dart';
import 'screens/analytics_screen.dart';
import 'screens/app_goals_screen.dart';
import 'screens/focus_screen.dart';
import 'screens/timeline_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/privacy_center_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_goal_store.dart';
import 'services/app_shell.dart';
import 'services/collector_client.dart';
import 'services/focus_store.dart';
import 'services/consent_store.dart';
import 'services/data_exporter.dart';
import 'services/privacy_data_store.dart';
import 'services/streak_store.dart';
import 'services/usage_controller.dart';
import 'services/usage_history_store.dart';
import 'services/user_settings_store.dart';
import 'theme/reboot_themes.dart';
import 'widgets/background_controls_card.dart';
import 'widgets/local_ai_card.dart';
import 'widgets/navigation.dart';

class RebootApp extends StatefulWidget {
  const RebootApp({
    super.key,
    this.settingsStore,
    this.privacyDataStore,
    this.streakStore,
    this.consentStore,
    this.historyStore,
    this.collector,
  });
  final UserSettingsStore? settingsStore;
  final PrivacyDataStore? privacyDataStore;
  final StreakStore? streakStore;
  final ConsentStore? consentStore;
  final UsageHistoryStore? historyStore;
  final UsageCollector? collector;

  @override
  State<RebootApp> createState() => _RebootAppState();
}

/// Owns only the active theme so a change in Settings restyles the whole app
/// without a restart. Settings themselves stay in [AppShell].
class _RebootAppState extends State<RebootApp> {
  AppThemeId _themeId = RebootThemes.fallback;

  void _applyTheme(AppThemeId id) {
    if (id != _themeId) setState(() => _themeId = id);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'REBOOT',
    debugShowCheckedModeBanner: false,
    theme: RebootThemes.build(_themeId),
    home: AppShell(
      settingsStore: widget.settingsStore,
      privacyDataStore: widget.privacyDataStore,
      streakStore: widget.streakStore,
      consentStore: widget.consentStore,
      historyStore: widget.historyStore,
      collector: widget.collector,
      onThemeChanged: _applyTheme,
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.settingsStore,
    this.privacyDataStore,
    this.streakStore,
    this.consentStore,
    this.historyStore,
    this.collector,
    this.onThemeChanged,
  });
  final UserSettingsStore? settingsStore;
  final PrivacyDataStore? privacyDataStore;
  final StreakStore? streakStore;
  final ConsentStore? consentStore;
  final UsageHistoryStore? historyStore;
  final UsageCollector? collector;
  final ValueChanged<AppThemeId>? onThemeChanged;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  late final AppShellBridge _shell;
  late final FocusStore _focus;
  late final AppGoalStore _goals;
  final _timelineKey = GlobalKey<TimelineScreenState>();
  final _shownAlerts = <String>{};
  Timer? _limitTimer;
  bool _limitDialogOpen = false;

  /// "Ещё 5 минут": app → moment until which its limit is not applied.
  final _snoozedUntil = <String, DateTime>{};

  /// "Снять ограничение на сегодня": app → the day it was released for.
  final _releasedOn = <String, LocalDay>{};
  late final UserSettingsStore _store;
  late final PrivacyDataStore _privacyDataStore;
  late final UsageController _usage;
  late final DataExporter _exporter;
  late final AppLifecycleListener _lifecycle;
  Timer? _dayTimer;
  LocalDay _today = LocalDay.today();
  UserSettings _settings = UserSettings.defaults;
  Future<void> _saveQueue = Future<void>.value();
  bool _loading = true;
  Object? _settingsLoadError;

  @override
  void initState() {
    super.initState();
    _store = widget.settingsStore ?? UserSettingsStore();
    _privacyDataStore = widget.privacyDataStore ?? PrivacyDataStore();
    final appDataPath = _privacyDataStore.appDataDirectoryPath;
    final appData = appDataPath == null ? null : Directory(appDataPath);
    _usage = UsageController(
      collector: widget.collector ?? MethodChannelUsageCollector(),
      history:
          widget.historyStore ??
          (appData == null
              ? UsageHistoryStore.unavailable()
              : UsageHistoryStore(directory: appData)),
      streak:
          widget.streakStore ??
          (appData == null
              ? StreakStore.unavailable()
              : StreakStore(directory: appData)),
      consent:
          widget.consentStore ??
          (appData == null
              ? ConsentStore.unavailable()
              : ConsentStore(directory: appData)),
    )..addListener(_onUsageChanged);
    _exporter = DataExporter(privacyStore: _privacyDataStore);
    _focus = appData == null
        ? FocusStore.unavailable()
        : FocusStore(directory: appData);
    _goals = appData == null
        ? AppGoalStore.unavailable()
        : AppGoalStore(directory: appData);
    _shell = AppShellBridge()..onTrayAction = _onTrayAction;
    // A minute tick plus resume catches midnight, sleep and time zone changes.
    _dayTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkDay());
    _limitTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_enforceLimits()),
    );
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _checkDay();
        unawaited(_usage.sync());
      },
      onHide: () => unawaited(_usage.sync()),
      // Cmd+Q, Dock "Quit", Windows close without background mode: save
      // what was collected, then let the app exit.
      onExitRequested: () async {
        await _usage.shutdown();
        return AppExitResponse.exit;
      },
    );
    _loadSettings();
  }

  @override
  void dispose() {
    _dayTimer?.cancel();
    _limitTimer?.cancel();
    _lifecycle.dispose();
    _usage
      ..removeListener(_onUsageChanged)
      ..dispose();
    _shell.dispose();
    super.dispose();
  }

  void _onUsageChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_pushTrayStatus());
    WidgetsBinding.instance.addPostFrameCallback((_) => _showGoalAlerts());
  }

  /// Menu bar / tray text: today's time, goal progress and collector state.
  Future<void> _pushTrayStatus() async {
    if (_usage.mode == UsageDataMode.demo) {
      await _shell.updateStatus(
        title: '',
        lines: const ['Демо-режим', 'Сбор не ведётся'],
        collecting: false,
      );
      return;
    }
    final today = _usage.index.day(_today).activeSeconds;
    final goal = _goalMinutes * 60;
    await _shell.updateStatus(
      title: formatHoursMinutes(today),
      lines: [
        'Сегодня: ${formatDuration(today)}',
        'Цель: ${formatMinutes(_goalMinutes)} · ${formatPercent(today / goal)}',
        _usage.isCollecting
            ? 'Сбор идёт'
            : (_usage.isPaused ? 'Сбор приостановлен' : 'Сбор не идёт'),
      ],
      collecting: _usage.isCollecting,
      progress: today / goal,
    );
  }

  void _showGoalAlerts() {
    if (!mounted || _usage.mode != UsageDataMode.real) return;
    final alerts = pendingAlerts(
      _goals.goals,
      _usage.index,
      _today,
      _shownAlerts,
    );
    final messenger = ScaffoldMessenger.maybeOf(context);
    for (final alert in alerts) {
      _shownAlerts.add(alert.key);
      messenger?.showSnackBar(SnackBar(content: Text(alert.message)));
    }
  }

  Future<void> _onTrayAction(TrayAction action) async {
    switch (action) {
      case TrayAction.open:
        await _shell.showWindow();
      case TrayAction.toggleCollection:
        if (_usage.isCollecting) {
          await _usage.pauseCollection();
        } else {
          await _usage.resumeCollection();
        }
      case TrayAction.quit:
        await _quit();
    }
  }

  /// Saves collected data, then ends the process.
  Future<void> _quit() async {
    await _usage.shutdown();
    if (_shell.state.available) {
      await _shell.quit();
    } else {
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    }
  }

  /// Soft limits: when an app whose limit is used up is in front, hide or
  /// minimise it and show REBOOT. Never closes apps or blocks launching.
  Future<void> _enforceLimits() async {
    if (!mounted ||
        _limitDialogOpen ||
        _usage.mode != UsageDataMode.real ||
        !_shell.state.available) {
      return;
    }
    final now = DateTime.now();
    final exhausted = exhaustedSoftLimits(
      goals: _goals.goals,
      index: _usage.index,
      today: _today,
      now: now,
      snoozedUntil: _snoozedUntil,
      releasedToday: {
        for (final e in _releasedOn.entries)
          if (e.value == _today) e.key,
      },
    );
    if (exhausted.isEmpty) return;
    final front = await _shell.frontmostApp();
    if (front == null) return;
    final goal = exhausted.where((g) => g.appId == front.appId).firstOrNull;
    if (goal == null || !mounted) return;
    final result = await _shell.limitApp(goal.appId);
    if (!mounted) return;
    _limitDialogOpen = true;
    final used = _usage.index.appDaily(goal.appId, _today, _today).single.$2;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.hourglass_bottom_rounded),
        title: Text('Лимит для ${goal.appName} исчерпан'),
        content: Text(
          'Сегодня: ${formatDuration(used)} из ${formatMinutes(goal.dailyLimitMinutes)}. '
          '${result.message}\n\nПриложение не закрыто — ограничение мягкое и '
          'работает, пока вы сами его не снимете.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'release'),
            child: const Text('Снять на сегодня'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'snooze'),
            child: const Text('Ещё 5 минут'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'ok'),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
    _limitDialogOpen = false;
    switch (choice) {
      case 'snooze':
        _snoozedUntil[goal.appId] = DateTime.now().add(
          const Duration(minutes: 5),
        );
      case 'release':
        _releasedOn[goal.appId] = _today;
    }
  }

  void _openTimeline(LocalDay day) {
    _select(AppSection.timeline);
    _timelineKey.currentState?.showDay(day);
  }

  void _checkDay() {
    final today = LocalDay.today();
    if (today != _today && mounted) setState(() => _today = today);
  }

  int get _goalMinutes => (_settings.goalHours * 60).round();

  Future<void> _loadSettings() async {
    setState(() {
      _loading = true;
      _settingsLoadError = null;
    });
    await _privacyDataStore.loadFeedback();
    try {
      final settings = await _store.loadSettings();
      if (!mounted) return;
      _settings = settings;
      _usage.goalMinutes = _goalMinutes;
      widget.onThemeChanged?.call(settings.themeId);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsLoadError = error;
        _loading = false;
      });
      return;
    }
    await _usage.load();
    await _focus.load();
    await _goals.load();
    await _shell.refresh();
    if (_shell.state.available) {
      await _shell.setBackgroundMode(_usage.choices.backgroundCollection);
    }
    if (!mounted) return;
    setState(() => _loading = false);
    unawaited(_pushTrayStatus());
  }

  void _saveSettings(UserSettings value) {
    setState(() => _settings = value);
    _usage.goalMinutes = _goalMinutes;
    widget.onThemeChanged?.call(value.themeId);
    _saveQueue = _saveQueue.then((_) => _store.saveSettings(value)).catchError((
      error,
    ) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Настройка изменилась, но не сохранилась для следующего запуска.',
            ),
          ),
        );
      }
    });
  }

  /// Stops collection, then deletes settings, feedback, usage history,
  /// streak days, focus sessions, app goals and consent, and turns off
  /// launch at login. Export files the user saved are not touched.
  Future<LocalDataDeletionResult> _deleteLocalData() async {
    await _saveQueue;
    await _usage.stopCollection();
    try {
      await _store.deleteSettings();
    } on Object {
      return LocalDataDeletionResult.settingsDeletionFailed;
    }
    try {
      await _privacyDataStore.clearFeedback();
    } on Object {
      _resetToDefaults();
      return LocalDataDeletionResult.feedbackDeletionFailedAfterSettings;
    }
    try {
      await _usage.clearUsageHistory();
      await _usage.clearConsent();
    } on Object {
      _resetToDefaults();
      return LocalDataDeletionResult.usageDataDeletionFailed;
    }
    try {
      await _usage.clearStreak();
      await _focus.clear();
      await _goals.clear();
    } on Object {
      _resetToDefaults();
      return LocalDataDeletionResult.streakDeletionFailedAfterFeedback;
    }
    if (_shell.state.launchAtLogin) await _shell.setLaunchAtLogin(false);
    if (_shell.state.available) await _shell.setBackgroundMode(true);
    _shownAlerts.clear();
    _resetToDefaults();
    return LocalDataDeletionResult.complete;
  }

  void _resetToDefaults() {
    if (!mounted) return;
    setState(() {
      _settings = UserSettings.defaults;
      _index = 0;
    });
    _usage.goalMinutes = _goalMinutes;
    widget.onThemeChanged?.call(UserSettings.defaults.themeId);
  }

  void _select(int value) => setState(() => _index = value);

  (String, String) get _sidebarStatus {
    if (_usage.mode == UsageDataMode.demo) {
      return ('Демо-режим', 'Показываются демонстрационные примеры');
    }
    return _usage.isCollecting
        ? (
            'Сбор идёт',
            _shell.state.backgroundMode
                ? 'Продолжится при закрытом окне'
                : 'Пока открыто окно REBOOT',
          )
        : _usage.isPaused
        ? ('Сбор приостановлен', 'Возобновить можно в Настройках')
        : ('Сбор остановлен', _usage.status?.message ?? 'Нет данных сборщика');
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      if (_loading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (_settingsLoadError != null) {
        return Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.storage_rounded,
                      color: context.palette.accent,
                      size: 36,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Настройки не удалось прочитать',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'REBOOT не загрузил сохранённые предпочтения. '
                      'Изменения пока недоступны, чтобы не заменить их значениями по умолчанию.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _loadSettings,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Повторить'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      if (!_usage.choices.onboardingCompleted) {
        return OnboardingScreen(
          controller: _usage,
          shell: _shell,
          settings: _settings,
          onSettingsChanged: _saveSettings,
        );
      }
      final real = _usage.mode == UsageDataMode.real;
      final index = real ? _usage.index : null;
      final streak = _usage.streakSummary(today: _today);
      final demoReport = real ? null : _usage.report(today: _today);
      final background = BackgroundControlsCard(
        controller: _usage,
        shell: _shell,
        onQuit: _quit,
      );
      final screens = [
        DashboardScreen(
          displayName: _settings.profileName,
          report: _usage.report(today: _today),
          streak: streak,
          status: _usage.status,
          onOpenPrivacy: () => _select(AppSection.privacy),
        ),
        AnalyticsScreen(
          mode: _usage.mode,
          today: _today,
          goalMinutes: _goalMinutes,
          streak: streak,
          index: index,
          demoReport: demoReport,
          onOpenTimeline: _openTimeline,
        ),
        TimelineScreen(
          key: _timelineKey,
          mode: _usage.mode,
          today: _today,
          index: index,
        ),
        FocusScreen(
          store: _focus,
          mode: _usage.mode,
          index: index,
          sessions: index?.sessions,
        ),
        AppGoalsScreen(store: _goals, mode: _usage.mode, index: index),
        InsightsScreen(
          mode: _usage.mode,
          today: _today,
          goalMinutes: _goalMinutes,
          streak: streak,
          index: index,
          demoReport: demoReport,
          focusTotals: real
              ? (from, to) => (
                  seconds: _focus.totalSeconds(from: from, to: to),
                  sessions: _focus.sessions.where((s) {
                    final d = LocalDay.fromDateTime(s.startedAt);
                    return !d.isBefore(from) && !to.isBefore(d);
                  }).length,
                )
              : null,
          onExport: _exporter.canExport ? _exporter.save : null,
        ),
        PrivacyCenterScreen(
          controller: _usage,
          settings: _settings,
          privacyDataStore: _privacyDataStore,
          onDeleteLocalData: _deleteLocalData,
          exporter: _exporter,
          backgroundControls: background,
          extraExportData: () => {
            'focusSessions': _focus.sessions.map((f) => f.toMap()).toList(),
            'appGoals': _goals.goals.map((g) => g.toMap()).toList(),
            'backgroundCollection': _usage.choices.backgroundCollection,
            'launchAtLogin': _shell.state.launchAtLogin,
          },
        ),
        SettingsScreen(
          settings: _settings,
          onChanged: _saveSettings,
          privacyDataStore: _privacyDataStore,
          onOpenPrivacy: () => _select(AppSection.privacy),
          backgroundControls: background,
          aiAssistant: LocalAiCard(controller: _usage, today: _today),
        ),
      ];
      final (statusTitle, statusBody) = _sidebarStatus;
      return Scaffold(
        body: Row(
          children: [
            if (wide)
              AppSidebar(
                index: _index,
                displayName: _settings.profileName,
                onSelect: _select,
                statusTitle: statusTitle,
                statusBody: statusBody,
                collecting: _usage.isCollecting,
              ),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: IndexedStack(index: _index, children: screens),
                  ),
                  if (!wide)
                    AppBottomNavigation(index: _index, onSelect: _select),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
