import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/focus_session.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_history.dart';
import '../models/usage_report.dart';
import '../services/focus_store.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/ui_kit.dart';

/// Focus timer with session history.
///
/// The timer reads wall-clock time, so it stays correct while the window is
/// minimised or the computer sleeps; the 1-second ticker only repaints.
class FocusScreen extends StatefulWidget {
  const FocusScreen({
    super.key,
    required this.store,
    required this.mode,
    this.index,
    this.sessions,
    this.clock,
  });

  final FocusStore store;
  final UsageDataMode mode;

  /// REAL history; used for the list of apps to mark as work.
  final HistoryIndex? index;

  /// Raw REAL foreground sessions, needed to clip app time to the exact
  /// interval of a focus session. Without them only the timer is shown.
  final List<AppSession>? sessions;
  final DateTime Function()? clock;

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  static const presets = [25, 50, 90];

  late final FocusTimer _timer = FocusTimer(clock: _now);
  Timer? _ticker;
  int _plannedMinutes = 25;
  bool _custom = false;
  bool _saving = false;
  String? _saveError;

  DateTime _now() => (widget.clock ?? DateTime.now)();
  LocalDay get _today => LocalDay.fromDateTime(_now());
  bool get _real => widget.mode == UsageDataMode.real && widget.index != null;

  @override
  void initState() {
    super.initState();
    if (!widget.store.isLoaded) {
      widget.store.load().whenComplete(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (!mounted) return;
    if (_timer.state == FocusTimerState.finished) {
      _ticker?.cancel();
      _ticker = null;
      unawaited(_save());
    }
    setState(() {});
  }

  void _start() {
    _timer.start(_plannedMinutes * 60, workAppIds: widget.store.workAppIds);
    _saveError = null;
    _startTicker();
    setState(() {});
  }

  void _pause() => setState(_timer.pause);

  void _resume() => setState(_timer.resume);

  Future<void> _finish() async {
    _timer.finish();
    _ticker?.cancel();
    _ticker = null;
    await _save();
  }

  Future<void> _save() async {
    final result = _timer.result;
    if (result == null || _saving) return;
    _saving = true;
    try {
      await widget.store.add(result);
      _saveError = null;
    } on Object {
      _saveError = 'Сессию не удалось сохранить в истории.';
    } finally {
      _saving = false;
      if (mounted) setState(() {});
    }
  }

  void _newSession() => setState(_timer.reset);

  Future<void> _pickCustom() async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => _CustomDurationDialog(initial: _plannedMinutes),
    );
    if (minutes == null || !mounted) return;
    setState(() {
      _plannedMinutes = minutes;
      _custom = !presets.contains(minutes);
    });
  }

  Future<void> _toggleWorkApp(String appId, bool selected) async {
    final next = {...widget.store.workAppIds};
    selected ? next.add(appId) : next.remove(appId);
    try {
      await widget.store.setWorkApps(next);
    } on Object {
      _saveError = 'Не удалось сохранить список рабочих приложений.';
    }
    if (mounted) setState(() {});
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Очистить историю фокуса?'),
        content: const Text(
          'Будут удалены все сессии и список рабочих приложений на этом устройстве.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final store = widget.store;
    return PageFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Фокус', style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 7),
            Text(
              'REBOOT не блокирует приложения — это таймер для самоконтроля.',
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
            const SizedBox(height: Gap.m),
            ModeBadge(mode: widget.mode),
            if (store.issue != null) ...[
              const SizedBox(height: Gap.m),
              EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'История фокуса только в памяти',
                body: store.issue!,
              ),
            ],
            const SizedBox(height: Gap.m),
            LayoutBuilder(
              builder: (context, constraints) {
                final timer = _timerCard(context);
                final side = _timer.state == FocusTimerState.finished
                    ? _summaryCard(context)
                    : _workAppsCard(context);
                if (constraints.maxWidth < 760) {
                  return Column(
                    children: [
                      timer,
                      const SizedBox(height: Gap.m),
                      side,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: timer),
                    const SizedBox(width: Gap.m),
                    Expanded(flex: 2, child: side),
                  ],
                );
              },
            ),
            const SizedBox(height: Gap.m),
            MetricGrid(
              maxColumns: 3,
              children: [
                MetricTile(
                  label: 'Фокус за 7 дней',
                  value: formatDuration(
                    store.totalForLastDays(7, today: _today),
                  ),
                  caption: 'включая сегодня',
                ),
                MetricTile(
                  label: 'Фокус за 30 дней',
                  value: formatDuration(
                    store.totalForLastDays(30, today: _today),
                  ),
                  caption: 'включая сегодня',
                ),
                MetricTile(
                  label: 'Сессий всего',
                  value: '${store.sessions.length}',
                  caption:
                      'завершено: ${store.sessions.where((s) => s.status == FocusStatus.completed).length}',
                ),
              ],
            ),
            const SizedBox(height: Gap.m),
            _historyCard(context),
          ],
        ),
      ),
    );
  }

  Widget _timerCard(BuildContext context) {
    final palette = context.palette;
    final state = _timer.state;
    final idle = state == FocusTimerState.idle;
    final seconds = idle ? _plannedMinutes * 60 : _timer.remainingSeconds;
    final label = switch (state) {
      FocusTimerState.idle => 'Готово к старту',
      FocusTimerState.running => 'Идёт сессия',
      FocusTimerState.paused => 'Пауза',
      FocusTimerState.finished => 'Сессия окончена',
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('Таймер'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final minutes in presets)
                ChoiceChip(
                  label: Text('$minutes мин'),
                  selected: !_custom && _plannedMinutes == minutes,
                  onSelected: idle
                      ? (_) => setState(() {
                          _plannedMinutes = minutes;
                          _custom = false;
                        })
                      : null,
                ),
              ChoiceChip(
                label: Text(_custom ? 'Своё: $_plannedMinutes мин' : 'Своё…'),
                selected: _custom,
                onSelected: idle ? (_) => _pickCustom() : null,
              ),
            ],
          ),
          const SizedBox(height: Gap.l),
          Semantics(
            liveRegion: true,
            label: 'Осталось ${formatDuration(seconds)}',
            child: ExcludeSemantics(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _clockText(seconds),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 72,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -2,
                      color: state == FocusTimerState.paused
                          ? palette.muted
                          : palette.text,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              label,
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          ),
          const SizedBox(height: Gap.m),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: idle ? 0 : _timer.progress,
              minHeight: 6,
              color: palette.accent,
              backgroundColor: palette.border.withValues(alpha: .5),
            ),
          ),
          const SizedBox(height: Gap.l),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: switch (state) {
              FocusTimerState.idle => [
                FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Старт'),
                ),
              ],
              FocusTimerState.running => [
                FilledButton.tonalIcon(
                  onPressed: _pause,
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('Пауза'),
                ),
                OutlinedButton.icon(
                  onPressed: _finish,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Завершить'),
                ),
              ],
              FocusTimerState.paused => [
                FilledButton.icon(
                  onPressed: _resume,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Продолжить'),
                ),
                OutlinedButton.icon(
                  onPressed: _finish,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Завершить'),
                ),
              ],
              FocusTimerState.finished => [
                FilledButton.icon(
                  onPressed: _newSession,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Новая сессия'),
                ),
              ],
            },
          ),
          if (_saveError != null) ...[
            const SizedBox(height: 10),
            Text(
              _saveError!,
              style: TextStyle(color: palette.danger, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  List<AppTotal> get _recentApps {
    final index = widget.index;
    if (!_real || index == null) return const [];
    return index.apps(_today.addDays(-6), _today).take(24).toList();
  }

  Widget _workAppsCard(BuildContext context) {
    final palette = context.palette;
    final apps = _recentApps;
    final selected = widget.store.workAppIds;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('Рабочие приложения'),
          const SizedBox(height: 6),
          Text(
            'Отметьте приложения, время в которых считается работой. После '
            'сессии REBOOT покажет, какую долю активного времени они заняли.',
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.45),
          ),
          const SizedBox(height: 12),
          if (!_real)
            Text(
              'Статистика приложений доступна только в режиме REAL',
              style: TextStyle(color: palette.muted, fontSize: 12),
            )
          else if (apps.isEmpty)
            Text(
              'За 7 дней нет данных о приложениях.',
              style: TextStyle(color: palette.muted, fontSize: 12),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final app in apps)
                  FilterChip(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(app.name, overflow: TextOverflow.ellipsis),
                    ),
                    selected: selected.contains(app.appId),
                    onSelected: (value) => _toggleWorkApp(app.appId, value),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    final palette = context.palette;
    final result = _timer.result!;
    final sessions = widget.sessions;
    final stats = _real && sessions != null
        ? focusAppStatsFor(result, sessions)
        : null;
    final share = stats?.workShare;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('Итоги сессии'),
          const SizedBox(height: 6),
          Text(
            result.status == FocusStatus.completed
                ? 'Завершена по плану'
                : 'Остановлена досрочно',
            style: TextStyle(
              color: result.status == FocusStatus.completed
                  ? palette.success
                  : palette.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          ValueRow(
            label: 'Длительность фокуса',
            value: formatDuration(result.focusedSeconds),
          ),
          ValueRow(label: 'План', value: formatDuration(result.plannedSeconds)),
          ValueRow(label: 'Паузы', value: formatDuration(result.pausedSeconds)),
          const Divider(height: 20),
          if (stats == null)
            Text(
              _real
                  ? 'Нет данных о сессиях приложений за это время.'
                  : 'Статистика приложений доступна только в режиме REAL',
              style: TextStyle(color: palette.muted, fontSize: 12),
            )
          else ...[
            ValueRow(
              label: 'Разных приложений',
              value: '${stats.distinctApps}',
            ),
            ValueRow(
              label: 'Активное время',
              value: formatDuration(stats.activeSeconds),
            ),
            ValueRow(
              label: 'В рабочих приложениях',
              secondary: share == null ? null : formatPercent(share),
              value: result.workAppIds.isEmpty
                  ? 'не выбраны'
                  : formatDuration(stats.workSeconds),
            ),
            const SizedBox(height: 4),
            Text(
              'По данным этого устройства. Последние секунды могут появиться '
              'после следующей синхронизации.',
              style: TextStyle(color: palette.muted, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  Widget _historyCard(BuildContext context) {
    final palette = context.palette;
    final sessions = widget.store.sessions;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            'История сессий',
            action: sessions.isEmpty ? null : 'Очистить',
            onAction: sessions.isEmpty ? null : _clearHistory,
          ),
          const SizedBox(height: 4),
          if (sessions.isEmpty)
            Text(
              'Сессий пока нет.',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          for (final session in sessions.take(20))
            ValueRow(
              leading: Icon(
                session.status == FocusStatus.completed
                    ? Icons.check_circle_outline_rounded
                    : Icons.stop_circle_outlined,
                size: 16,
                color: session.status == FocusStatus.completed
                    ? palette.success
                    : palette.muted,
              ),
              label: _sessionLabel(session),
              secondary: 'из ${formatMinutes(session.plannedSeconds ~/ 60)}',
              value: formatDuration(session.focusedSeconds),
            ),
        ],
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _sessionLabel(FocusSession session) {
    final t = session.startedAt.toLocal();
    return '${weekdayShort(t.weekday)}, ${_two(t.day)}.${_two(t.month)} '
        '${_two(t.hour)}:${_two(t.minute)}';
  }

  static String _clockText(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '$h:${_two(m)}:${_two(sec)}' : '${_two(m)}:${_two(sec)}';
  }
}

class _CustomDurationDialog extends StatefulWidget {
  const _CustomDurationDialog({required this.initial});
  final int initial;

  @override
  State<_CustomDurationDialog> createState() => _CustomDurationDialogState();
}

class _CustomDurationDialogState extends State<_CustomDurationDialog> {
  late final _controller = TextEditingController(text: '${widget.initial}');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null ||
        value < FocusTimer.minMinutes ||
        value > FocusTimer.maxMinutes) {
      setState(
        () => _error =
            'От ${FocusTimer.minMinutes} до ${FocusTimer.maxMinutes} минут',
      );
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Своя длительность'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: 'Минуты',
        helperText:
            'От ${FocusTimer.minMinutes} до ${FocusTimer.maxMinutes} минут',
        errorText: _error,
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Готово')),
    ],
  );
}
