import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/insights.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/app_usage_tile.dart';
import '../widgets/interactive_charts.dart';
import '../widgets/ui_kit.dart';

typedef FocusTotals = ({int seconds, int sessions});

/// Weekly report, smart insights and general ideas. Everything is plain
/// arithmetic over stored data; rules stay silent without enough data.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({
    super.key,
    required this.mode,
    required this.today,
    required this.goalMinutes,
    required this.streak,
    this.index,
    this.demoReport,
    this.focusTotals,
    this.onExport,
  });

  final UsageDataMode mode;
  final LocalDay today;
  final int goalMinutes;
  final StreakSummary streak;
  final HistoryIndex? index;
  final UsageReport? demoReport;
  final FocusTotals? Function(LocalDay from, LocalDay to)? focusTotals;

  /// Saves the report; returns the path or `null` when cancelled.
  final Future<String?> Function(String suggestedName, String content)?
  onExport;

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  int _weekOffset = 0;

  bool get _isDemo => widget.mode == UsageDataMode.demo || widget.index == null;

  WeeklyReport _week() {
    if (_isDemo) {
      final usage =
          widget.demoReport ??
          buildDemoReport(demoUsage.withTarget(widget.goalMinutes));
      return WeeklyReport(
        mode: UsageDataMode.demo,
        start: usage.days.first.day,
        usage: usage,
        heatmap: null,
        streak: widget.streak,
        focusSeconds: null,
        focusSessions: null,
      );
    }
    final start = weekStart(widget.today).addDays(-7 * _weekOffset);
    final sunday = start.addDays(6);
    final end = widget.today.isBefore(sunday) ? widget.today : sunday;
    final index = widget.index!;
    final focus = widget.focusTotals?.call(start, end);
    return WeeklyReport(
      mode: UsageDataMode.real,
      start: start,
      usage: buildRangeReport(
        index: index,
        from: start,
        to: end,
        goalMinutes: widget.goalMinutes,
      ),
      heatmap: index.heatmap(start, end),
      streak: widget.streak,
      focusSeconds: focus?.seconds,
      focusSessions: focus?.sessions,
    );
  }

  List<Insight> _insights() {
    if (_isDemo) {
      return buildInsights(
        week:
            widget.demoReport ??
            buildDemoReport(demoUsage.withTarget(widget.goalMinutes)),
      );
    }
    final index = widget.index!;
    final week = buildRangeReport(
      index: index,
      from: widget.today.addDays(-6),
      to: widget.today,
      goalMinutes: widget.goalMinutes,
    );
    final from = widget.today.addDays(-29);
    final heatDays = [
      for (var d = from; !widget.today.isBefore(d); d = d.addDays(1))
        if ((index.day(d).coverageSeconds ?? 0) > 0) d,
    ].length;
    return buildInsights(
      week: week,
      heatmap: index.heatmap(from, widget.today),
      heatmapDays: heatDays,
    );
  }

  Future<void> _export(WeeklyReport week) async {
    final save = widget.onExport;
    if (save == null) return;
    try {
      final path = await save(
        'reboot-weekly-report-${week.start.key}.json',
        const JsonEncoder.withIndent('  ').convert(week.toMap()),
      );
      if (path == null || !mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Отчёт сохранён: $path')));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить отчёт.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final week = _week();
    final usage = week.usage;
    final change = usage.changeFraction;
    final insights = _insights();
    final mostDay = week.mostActiveDay;
    final mostHour = week.mostActiveHour;
    final withData = week.daysWithData;
    return PageFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Отчёт и выводы',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 7),
            Text(
              _isDemo
                  ? 'Пример недельного отчёта на демонстрационных данных'
                  : 'Недельный отчёт по данным этого устройства',
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
            const SizedBox(height: Gap.m),
            ModeBadge(mode: week.mode),
            const SizedBox(height: Gap.m),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton.outlined(
                  tooltip: 'Предыдущая неделя',
                  onPressed: _isDemo || _weekOffset >= 12
                      ? null
                      : () => setState(() => _weekOffset++),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Text(
                  '${shortDate(week.start)} — ${shortDate(week.end)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                IconButton.outlined(
                  tooltip: 'Следующая неделя',
                  onPressed: _weekOffset == 0
                      ? null
                      : () => setState(() => _weekOffset--),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
                if (widget.onExport != null)
                  OutlinedButton.icon(
                    onPressed: () => _export(week),
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: const Text('Экспорт отчёта'),
                  ),
              ],
            ),
            const SizedBox(height: Gap.m),
            if (!week.hasEnoughData)
              EmptyState(
                icon: Icons.hourglass_empty_rounded,
                title: 'Недостаточно данных для отчёта',
                body:
                    'За эту неделю дней со сбором: $withData. Отчёт появится, когда их будет хотя бы 3.',
              )
            else ...[
              MetricGrid(
                children: [
                  MetricTile(
                    label: 'Экранное время',
                    value: formatDuration(usage.periodActiveSeconds),
                    caption: 'дней с данными: $withData',
                  ),
                  MetricTile(
                    label: 'К прошлой неделе',
                    value: change == null
                        ? '—'
                        : '${change <= 0 ? '−' : '+'}${formatPercent(change.abs())}',
                    caption: change == null
                        ? 'нет данных для сравнения'
                        : 'было ${formatDuration(usage.previousActiveSeconds)}',
                  ),
                  MetricTile(
                    label: 'Цель выполнена',
                    value: '${usage.daysWithinGoal} из $withData',
                    caption: 'дней, цель ${formatMinutes(usage.goalMinutes)}',
                  ),
                  MetricTile(
                    label: 'Запуски',
                    value: usage.periodLaunches?.toString() ?? '—',
                    caption: usage.periodLaunches == null
                        ? 'нет в демо-данных'
                        : 'за неделю',
                  ),
                  MetricTile(
                    label: 'Самый активный день',
                    value: mostDay == null ? '—' : shortDate(mostDay.day),
                    caption: mostDay == null
                        ? 'нет данных'
                        : formatDuration(mostDay.activeSeconds),
                  ),
                  MetricTile(
                    label: 'Самый активный час',
                    value: mostHour == null
                        ? '—'
                        : hourRange(mostHour, mostHour + 1),
                    caption: mostHour == null
                        ? 'нет почасовых данных'
                        : 'за неделю',
                  ),
                  MetricTile(
                    label: 'Серия',
                    value: '${week.streak.current} дн.',
                    caption: 'рекорд ${week.streak.best} дн.',
                  ),
                  MetricTile(
                    label: 'Фокус-сессии',
                    value: week.focusSeconds == null
                        ? '—'
                        : formatDuration(week.focusSeconds!),
                    caption: week.focusSessions == null
                        ? 'только в режиме REAL'
                        : 'сессий: ${week.focusSessions}',
                  ),
                ],
              ),
              const SizedBox(height: Gap.m),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeading('Сравнение по дням'),
                    const SizedBox(height: 10),
                    InteractiveLineChart(
                      days: [for (final d in usage.days) d.day],
                      goalSeconds: usage.goalMinutes * 60,
                      height: 200,
                      series: [
                        ChartSeries(
                          label: 'Эта неделя',
                          color: palette.accent,
                          values: [
                            for (final d in usage.days)
                              d.hasData ? d.activeSeconds : null,
                          ],
                        ),
                        ChartSeries(
                          label: 'Прошлая неделя',
                          color: palette.muted,
                          dashed: true,
                          values: [
                            for (final d in usage.previousDays)
                              d.hasData ? d.activeSeconds : null,
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.m),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeading('Топ-5 приложений'),
                    const SizedBox(height: 4),
                    if (week.topApps.isEmpty)
                      Text(
                        'Нет данных о приложениях.',
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                    for (var i = 0; i < week.topApps.length; i++)
                      AppUsageTile(
                        app: week.topApps[i],
                        rank: i + 1,
                        totalSeconds: usage.periodActiveSeconds,
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            const SectionHeading('Выводы'),
            const SizedBox(height: 10),
            if (insights.isEmpty)
              const EmptyState(
                icon: Icons.insights_outlined,
                title: 'Пока недостаточно данных для выводов',
                body: 'Выводы появляются, когда накопится несколько дней статистики. Мы не делаем выводов по одному дню.',
              ),
            for (final insight in insights) ...[
              AppCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.insights_outlined,
                      color: palette.accent,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            insight.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            insight.detail,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_isDemo ? 'Пример на демо-данных · ' : ''}${insight.basis}',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 10),
            const SectionHeading('Три идеи для самостоятельного эксперимента'),
            const SizedBox(height: 10),
            const _Idea(
              number: '01',
              icon: Icons.flag_outlined,
              title: 'Выбери ориентир',
              body: 'Сравни дневное значение с целью, которая комфортна именно тебе. Цель меняется в настройках и не является рекомендацией.',
            ),
            const SizedBox(height: 10),
            const _Idea(
              number: '02',
              icon: Icons.pause_circle_outline,
              title: 'Попробуй короткую паузу',
              body: 'Если это подходит твоим задачам, отложи устройство между делами и отметь, как тебе такой перерыв.',
            ),
            const SizedBox(height: 10),
            const _Idea(
              number: '03',
              icon: Icons.tune_rounded,
              title: 'Понаблюдай за одним приложением',
              body: 'Выбери одно приложение в Аналитике и реши, хочешь ли ты что-то менять. Ограничение можно включить в «Целях»; без этого REBOOT ничего не ограничивает и не оценивает.',
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'Это не медицинская оценка и не диагностика. REBOOT показывает только время использования.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.muted, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Idea extends StatelessWidget {
  const _Idea({
    required this.number,
    required this.icon,
    required this.title,
    required this.body,
  });
  final String number, title, body;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            number,
            style: TextStyle(
              color: palette.accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Icon(icon, color: palette.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
