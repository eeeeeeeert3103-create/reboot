import 'package:flutter/material.dart';

import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_history.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/app_usage_tile.dart';
import '../widgets/interactive_charts.dart';
import '../widgets/ui_kit.dart';

String clockTime(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Drill-down for one local day: totals, hours, apps.
class DayDetailScreen extends StatelessWidget {
  const DayDetailScreen({
    super.key,
    required this.day,
    required this.index,
    required this.goalMinutes,
    this.onOpenTimeline,
  });

  final LocalDay day;
  final HistoryIndex index;
  final int goalMinutes;
  final ValueChanged<LocalDay>? onOpenTimeline;

  static Future<void> open(
    BuildContext context, {
    required LocalDay day,
    required HistoryIndex index,
    required int goalMinutes,
    ValueChanged<LocalDay>? onOpenTimeline,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DayDetailScreen(
        day: day,
        index: index,
        goalMinutes: goalMinutes,
        onOpenTimeline: onOpenTimeline,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final usage = index.day(day);
    final apps = index.apps(day, day);
    final hours = index.hourly(day);
    final goal = goalMinutes * 60;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        title: Text(shortDate(day)),
        actions: [
          if (onOpenTimeline != null)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                onOpenTimeline!(day);
              },
              icon: const Icon(Icons.view_timeline_outlined, size: 18),
              label: const Text('Лента дня'),
            ),
        ],
      ),
      body: PageFrame(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!usage.hasData)
                const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'В этот день сбор не шёл',
                  body: 'REBOOT не был запущен или сбор был выключен. Это не означает нулевое использование.',
                )
              else ...[
                MetricGrid(
                  children: [
                    MetricTile(
                      label: 'Экранное время',
                      value: formatDuration(usage.activeSeconds),
                      caption: usage.activeSeconds <= goal
                          ? 'в пределах цели ${formatMinutes(goalMinutes)}'
                          : 'выше цели на ${formatDuration(usage.activeSeconds - goal)}',
                    ),
                    MetricTile(
                      label: 'Запуски',
                      value: '${usage.launches ?? 0}',
                      caption: 'приложений',
                    ),
                    MetricTile(
                      label: 'Бездействие',
                      value: formatDuration(usage.idleSeconds),
                      caption: 'без ввода ≥ 2 мин',
                    ),
                    MetricTile(
                      label: 'Сбор шёл',
                      value: formatDuration(usage.coverageSeconds ?? 0),
                      caption: 'из 24 ч',
                    ),
                  ],
                ),
                const SizedBox(height: Gap.m),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeading('По часам'),
                      const SizedBox(height: 10),
                      HourBars(hours: hours),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: Gap.m),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeading('Приложения'),
                    const SizedBox(height: 4),
                    if (apps.isEmpty)
                      Text(
                        'Нет активных приложений за этот день.',
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                    for (var i = 0; i < apps.length; i++)
                      AppUsageTile(
                        app: apps[i],
                        rank: i + 1,
                        totalSeconds: usage.activeSeconds,
                        onTap: () => AppDetailScreen.open(
                          context,
                          app: apps[i],
                          from: day,
                          to: day,
                          index: index,
                          goalMinutes: goalMinutes,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 24 small bars with exact values on hover.
class HourBars extends StatelessWidget {
  const HourBars({super.key, required this.hours, this.height = 120});
  final List<int> hours;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final max = hours.fold(0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: height + 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var h = 0; h < 24; h++)
            Expanded(
              child: Tooltip(
                message:
                    '${h.toString().padLeft(2, '0')}:00–${((h + 1) % 24).toString().padLeft(2, '0')}:00 · ${formatDuration(hours[h])}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: max == 0 ? 2 : 2 + (height - 2) * hours[h] / max,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: hours[h] == 0
                            ? palette.border
                            : palette.accent.withValues(alpha: .85),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    SizedBox(
                      height: 16,
                      child: h % 6 == 0
                          ? Text(
                              '$h',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 9,
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One app over a range: totals, per-day bars, every session.
class AppDetailScreen extends StatelessWidget {
  const AppDetailScreen({
    super.key,
    required this.app,
    required this.from,
    required this.to,
    required this.index,
    required this.goalMinutes,
  });

  final AppTotal app;
  final LocalDay from;
  final LocalDay to;
  final HistoryIndex index;
  final int goalMinutes;

  static Future<void> open(
    BuildContext context, {
    required AppTotal app,
    required LocalDay from,
    required LocalDay to,
    required HistoryIndex index,
    required int goalMinutes,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppDetailScreen(
        app: app,
        from: from,
        to: to,
        index: index,
        goalMinutes: goalMinutes,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final daily = index.appDaily(app.appId, from, to);
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day + 1);
    final sessions = index
        .sessionsIn(start, end, appId: app.appId)
        .reversed
        .toList();
    final activeDays = daily.where((d) => d.$2 > 0).length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        title: Text(app.name, overflow: TextOverflow.ellipsis),
      ),
      body: PageFrame(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${app.appId} · ${from == to ? shortDate(from) : '${shortDate(from)} — ${shortDate(to)}'}',
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
              const SizedBox(height: Gap.m),
              MetricGrid(
                children: [
                  MetricTile(
                    label: 'Активное время',
                    value: formatDuration(app.activeSeconds),
                  ),
                  MetricTile(label: 'Запуски', value: '${app.launches ?? 0}'),
                  MetricTile(label: 'Сессии', value: '${app.sessions ?? 0}'),
                  MetricTile(
                    label: 'Самая длинная',
                    value: formatDuration(app.longestSessionSeconds ?? 0),
                    caption: 'непрерывная сессия',
                  ),
                ],
              ),
              if (daily.length > 1) ...[
                const SizedBox(height: Gap.m),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeading(
                        'По дням · в среднем ${formatDuration(activeDays == 0 ? 0 : app.activeSeconds ~/ activeDays)} в день использования',
                      ),
                      const SizedBox(height: 10),
                      InteractiveBarChart(
                        days: [
                          for (final (d, seconds) in daily)
                            DayUsage(
                              day: d,
                              activeSeconds: seconds,
                              coverageSeconds: index.day(d).coverageSeconds,
                            ),
                        ],
                        goalMinutes: goalMinutes,
                        height: 200,
                      ),
                      Text(
                        'Пунктир — общая дневная цель, для масштаба.',
                        style: TextStyle(color: palette.muted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: Gap.m),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeading('История сессий · ${sessions.length}'),
                    const SizedBox(height: 4),
                    if (sessions.isEmpty)
                      Text(
                        'Сессий за период нет.',
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                    for (final s in sessions.take(300))
                      ValueRow(
                        label: from == to
                            ? '${clockTime(s.start)}–${clockTime(s.end)}'
                            : '${shortDate(LocalDay.fromDateTime(s.start))}, ${clockTime(s.start)}–${clockTime(s.end)}',
                        value: formatDuration(s.duration.inSeconds),
                      ),
                    if (sessions.length > 300)
                      Text(
                        'Показаны последние 300 сессий.',
                        style: TextStyle(color: palette.muted, fontSize: 10),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Details of one stored session, used by the timeline.
Future<void> showSessionDetails(BuildContext context, AppSession session) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(session.appName, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueRow(label: 'Начало', value: clockTime(session.start)),
              ValueRow(label: 'Конец', value: clockTime(session.end)),
              ValueRow(
                label: 'Длительность',
                value: formatDuration(session.duration.inSeconds),
              ),
              ValueRow(label: 'Идентификатор', value: session.appId),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
