import 'package:flutter/material.dart';

import '../models/app_goal.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_report.dart';
import '../services/app_goal_store.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/ui_kit.dart';

/// Daily per-app goals with progress and a 14-day history.
class AppGoalsScreen extends StatefulWidget {
  const AppGoalsScreen({
    super.key,
    required this.store,
    required this.mode,
    this.index,
    this.clock,
  });

  final AppGoalStore store;
  final UsageDataMode mode;

  /// REAL history; `null` or ignored in DEMO.
  final HistoryIndex? index;
  final DateTime Function()? clock;

  @override
  State<AppGoalsScreen> createState() => _AppGoalsScreenState();
}

class _AppGoalsScreenState extends State<AppGoalsScreen> {
  String? _error;

  LocalDay get _today =>
      LocalDay.fromDateTime((widget.clock ?? DateTime.now)());
  HistoryIndex? get _realIndex =>
      widget.mode == UsageDataMode.real ? widget.index : null;

  @override
  void initState() {
    super.initState();
    if (!widget.store.isLoaded) {
      widget.store.load().whenComplete(() {
        if (mounted) setState(() {});
      });
    }
  }

  /// Apps seen in the last 30 days (REAL) or the demo fixtures (DEMO).
  List<AppTotal> get _candidates {
    final index = _realIndex;
    if (index != null) return index.apps(_today.addDays(-29), _today);
    if (widget.mode == UsageDataMode.demo) {
      return buildDemoReport(demoUsage).appsToday;
    }
    return const [];
  }

  Future<void> _run(Future<Object?> Function() action) async {
    try {
      await action();
      _error = null;
    } on Object {
      _error = 'Не удалось сохранить изменения.';
    }
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final taken = widget.store.goals.map((g) => g.appId).toSet();
    final apps = _candidates.where((a) => !taken.contains(a.appId)).toList();
    final result = await showDialog<_GoalDraft>(
      context: context,
      builder: (_) => _GoalDialog(apps: apps),
    );
    if (result == null) return;
    await _run(
      () => widget.store.add(
        AppGoal(
          appId: result.appId,
          appName: result.appName,
          dailyLimitMinutes: result.limitMinutes,
          warnEnabled: result.warn,
          softLimit: result.softLimit,
          createdAt: (widget.clock ?? DateTime.now)(),
        ),
      ),
    );
  }

  Future<void> _edit(AppGoal goal) async {
    final result = await showDialog<_GoalDraft>(
      context: context,
      builder: (_) => _GoalDialog(apps: const [], editing: goal),
    );
    if (result == null) return;
    await _run(
      () => widget.store.update(
        goal.copyWith(
          dailyLimitMinutes: result.limitMinutes,
          warnEnabled: result.warn,
          softLimit: result.softLimit,
        ),
      ),
    );
  }

  Future<void> _remove(AppGoal goal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить цель?'),
        content: Text('Цель для «${goal.appName}» будет удалена.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(() => widget.store.remove(goal.appId));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final goals = widget.store.goals;
    final index = _realIndex;
    final demo = widget.mode == UsageDataMode.demo;
    return PageFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Цели по приложениям',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 7),
            Text(
              'Дневной лимит для отдельных приложений: прогресс, напоминания и, '
              'если включить, мягкое ограничение — после лимита REBOOT скрывает '
              'приложение, когда оно на переднем плане. Ничего не закрывается '
              'и не удаляется.',
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
            const SizedBox(height: Gap.m),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ModeBadge(mode: widget.mode),
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Добавить цель'),
                ),
              ],
            ),
            if (index == null) ...[
              const SizedBox(height: Gap.m),
              EmptyState(
                icon: Icons.info_outline_rounded,
                title: demo ? 'Демо-режим' : 'Нет данных',
                body:
                    'Прогресс считается только по данным REAL. Цели можно '
                    'создать заранее${demo ? ' — список приложений взят из демо-примера' : ''}.',
              ),
            ],
            if (widget.store.issue != null || _error != null) ...[
              const SizedBox(height: Gap.m),
              EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Цели сохраняются только в памяти',
                body: _error ?? widget.store.issue!,
              ),
            ],
            const SizedBox(height: Gap.m),
            if (goals.isEmpty)
              EmptyState(
                icon: Icons.flag_outlined,
                title: 'Целей пока нет',
                body:
                    'Выберите приложение и дневной лимит — например, 60 минут '
                    'для видео.',
                action: 'Добавить цель',
                onAction: _add,
              ),
            for (final goal in goals) ...[
              _GoalCard(
                goal: goal,
                progress: index == null
                    ? null
                    : AppGoalProgress.compute(
                        goal: goal,
                        index: index,
                        today: _today,
                      ),
                onEdit: () => _edit(goal),
                onRemove: () => _remove(goal),
              ),
              const SizedBox(height: Gap.m),
            ],
            if (goals.isNotEmpty && index != null)
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  _Legend(color: palette.success, label: 'В пределах цели'),
                  _Legend(color: palette.danger, label: 'Выше цели'),
                  _Legend(
                    color: palette.border,
                    label: 'Нет данных',
                    outline: true,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.progress,
    required this.onEdit,
    required this.onRemove,
  });

  final AppGoal goal;
  final AppGoalProgress? progress;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final p = progress;
    final color = switch (p?.status) {
      AppGoalStatus.reached => palette.danger,
      AppGoalStatus.near => palette.warning,
      _ => palette.accent,
    };
    final statusText = switch (p?.status) {
      AppGoalStatus.reached => 'Цель достигнута',
      AppGoalStatus.near => 'Почти у цели',
      AppGoalStatus.ok => 'В пределах',
      null => 'Прогресс считается только по данным REAL',
    };
    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppMonogram(name: goal.appName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Лимит ${formatMinutes(goal.dailyLimitMinutes)} в день'
                      '${goal.warnEnabled ? ' · напоминание' : ''}'
                      '${goal.softLimit ? ' · ограничение' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Действия',
                icon: Icon(Icons.more_horiz_rounded, color: palette.muted),
                onSelected: (value) => value == 'edit' ? onEdit() : onRemove(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Изменить')),
                  PopupMenuItem(value: 'remove', child: Text('Удалить')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (p == null)
            Text(
              statusText,
              style: TextStyle(color: palette.muted, fontSize: 12),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${formatMinutes(p.usedSeconds ~/ 60)} из '
                  '${formatMinutes(goal.dailyLimitMinutes)}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Semantics(
              label: 'Использовано ${formatPercent(p.fraction)} лимита',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: p.fraction.clamp(0.0, 1.0),
                  minHeight: 6,
                  color: color,
                  backgroundColor: palette.border.withValues(alpha: .5),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: Eyebrow('14 дней')),
                Text(
                  'в пределах: ${p.metDays} из ${p.daysWithData}',
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _HistoryStrip(
              days: p.history,
              limitSeconds: goal.dailyLimitSeconds,
            ),
          ],
        ],
      ),
    );
  }
}

/// Fourteen mini bars, one per finished day, oldest on the left.
class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({required this.days, required this.limitSeconds});
  final List<AppGoalDay> days;
  final int limitSeconds;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    const height = 28.0;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < days.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Tooltip(
                message: _tooltip(days[i]),
                child: Container(
                  height: days[i].result == GoalDayResult.noData
                      ? height
                      : (height *
                                (days[i].usedSeconds / (limitSeconds * 1.5))
                                    .clamp(.12, 1.0))
                            .toDouble(),
                  decoration: BoxDecoration(
                    color: switch (days[i].result) {
                      GoalDayResult.met => palette.success,
                      GoalDayResult.exceeded => palette.danger,
                      GoalDayResult.noData => null,
                    },
                    borderRadius: BorderRadius.circular(3),
                    border: days[i].result == GoalDayResult.noData
                        ? Border.all(color: palette.border)
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _tooltip(AppGoalDay d) {
    final date =
        '${weekdayShort(d.day.weekday)}, ${d.day.day.toString().padLeft(2, '0')}.${d.day.month.toString().padLeft(2, '0')}';
    return d.result == GoalDayResult.noData
        ? '$date: нет данных'
        : '$date: ${formatDuration(d.usedSeconds)}';
  }
}

class _GoalDraft {
  const _GoalDraft(
    this.appId,
    this.appName,
    this.limitMinutes,
    this.warn,
    this.softLimit,
  );
  final String appId;
  final String appName;
  final int limitMinutes;
  final bool warn;
  final bool softLimit;
}

class _GoalDialog extends StatefulWidget {
  const _GoalDialog({required this.apps, this.editing});
  final List<AppTotal> apps;
  final AppGoal? editing;

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  late String? _appId =
      widget.editing?.appId ??
      (widget.apps.isEmpty ? null : widget.apps.first.appId);
  late double _limit = (widget.editing?.dailyLimitMinutes ?? 60).toDouble();
  late bool _warn = widget.editing?.warnEnabled ?? true;
  late bool _soft = widget.editing?.softLimit ?? false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final editing = widget.editing;
    final canSave = _appId != null;
    return AlertDialog(
      title: Text(editing == null ? 'Новая цель' : 'Изменить цель'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (editing != null)
                Text(
                  editing.appName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                )
              else if (widget.apps.isEmpty)
                Text(
                  'Нет приложений за последние 30 дней, для которых ещё нет цели.',
                  style: TextStyle(color: palette.muted, fontSize: 12),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _appId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Приложение'),
                  items: [
                    for (final app in widget.apps)
                      DropdownMenuItem(
                        value: app.appId,
                        child: Text(
                          '${app.name} · ${formatDuration(app.activeSeconds)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _appId = value),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(child: Eyebrow('Дневной лимит')),
                  Text(
                    formatMinutes(_limit.round()),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              Slider(
                value: _limit,
                min: AppGoal.minLimitMinutes.toDouble(),
                max: AppGoal.maxLimitMinutes.toDouble(),
                divisions:
                    (AppGoal.maxLimitMinutes - AppGoal.minLimitMinutes) ~/ 5,
                label: formatMinutes(_limit.round()),
                onChanged: (value) => setState(() => _limit = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _warn,
                onChanged: (value) => setState(() => _warn = value),
                title: const Text(
                  'Напоминать в REBOOT',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  'При 80% и 100% лимита, один раз в день. Это сообщение '
                  'внутри приложения, не системное уведомление.',
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _soft,
                onChanged: (value) => setState(() => _soft = value),
                title: const Text(
                  'Ограничивать после лимита',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  'Когда лимит исчерпан, REBOOT скрывает (macOS) или сворачивает '
                  '(Windows) это приложение, если оно на переднем плане, и '
                  'показывает своё окно. Приложение не закрывается; можно '
                  'дать себе ещё 5 минут или снять ограничение на сегодня.',
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: canSave
              ? () {
                  final name =
                      editing?.appName ??
                      widget.apps.firstWhere((a) => a.appId == _appId).name;
                  Navigator.pop(
                    context,
                    _GoalDraft(_appId!, name, _limit.round(), _warn, _soft),
                  );
                }
              : null,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    this.outline = false,
  });

  final Color color;
  final String label;
  final bool outline;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: outline ? null : color,
          borderRadius: BorderRadius.circular(2),
          border: outline ? Border.all(color: color) : null,
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: context.palette.muted, fontSize: 10)),
    ],
  );
}
