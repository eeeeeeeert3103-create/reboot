import 'package:flutter/material.dart';

import '../models/insights.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/app_usage_tile.dart';
import '../widgets/charts.dart';
import '../widgets/interactive_charts.dart';
import '../widgets/streak_widgets.dart';
import '../widgets/ui_kit.dart';
import 'day_detail_screen.dart';

enum AnalyticsRange { today, yesterday, last7, last30, last90, custom }

extension on AnalyticsRange {
  String get label => switch (this) {
    AnalyticsRange.today => 'Сегодня',
    AnalyticsRange.yesterday => 'Вчера',
    AnalyticsRange.last7 => '7 дней',
    AnalyticsRange.last30 => '30 дней',
    AnalyticsRange.last90 => '90 дней',
    AnalyticsRange.custom => 'Период…',
  };
}

enum _ChartKind { bars, line }

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({
    super.key,
    required this.mode,
    required this.today,
    required this.goalMinutes,
    required this.streak,
    this.index,
    this.demoReport,
    this.onOpenTimeline,
  });

  final UsageDataMode mode;
  final LocalDay today;
  final int goalMinutes;
  final StreakSummary streak;

  /// Real history; `null` in DEMO.
  final HistoryIndex? index;

  /// Prepared demo fixtures, shown with a DEMO label.
  final UsageReport? demoReport;
  final ValueChanged<LocalDay>? onOpenTimeline;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  AnalyticsRange _range = AnalyticsRange.last7;
  DateTimeRange? _custom;
  _ChartKind _chart = _ChartKind.bars;
  String? _lineApp;
  bool _compare = false;
  String? _heatApp;

  bool get _isDemo => widget.mode == UsageDataMode.demo || widget.index == null;

  (LocalDay, LocalDay) get _bounds {
    final t = widget.today;
    return switch (_range) {
      AnalyticsRange.today => (t, t),
      AnalyticsRange.yesterday => (t.addDays(-1), t.addDays(-1)),
      AnalyticsRange.last7 => (t.addDays(-6), t),
      AnalyticsRange.last30 => (t.addDays(-29), t),
      AnalyticsRange.last90 => (t.addDays(-89), t),
      AnalyticsRange.custom =>
        _custom == null
            ? (t.addDays(-6), t)
            : (
                LocalDay.fromDateTime(_custom!.start),
                LocalDay.fromDateTime(_custom!.end),
              ),
    };
  }

  UsageReport get _report {
    if (_isDemo) {
      return widget.demoReport ??
          buildDemoReport(demoUsage.withTarget(widget.goalMinutes));
    }
    final (from, to) = _bounds;
    return buildRangeReport(
      index: widget.index!,
      from: from,
      to: to,
      goalMinutes: widget.goalMinutes,
    );
  }

  Future<void> _selectRange(AnalyticsRange range) async {
    if (range == AnalyticsRange.custom) {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: now.subtract(const Duration(days: 89)),
        lastDate: now,
        initialDateRange: _custom,
        helpText: 'Выберите период',
      );
      if (picked == null) return;
      setState(() {
        _custom = picked;
        _range = range;
      });
      return;
    }
    setState(() => _range = range);
  }

  void _openDay(LocalDay day) {
    final index = widget.index;
    if (_isDemo || index == null) return;
    DayDetailScreen.open(
      context,
      day: day,
      index: index,
      goalMinutes: widget.goalMinutes,
      onOpenTimeline: widget.onOpenTimeline,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final report = _report;
    final change = report.changeFraction;
    final withData = report.daysWithData.length;
    final apps = report.appsPeriod ?? report.appsToday;
    final appsTotal = report.appsPeriod == null
        ? report.todayUsage.activeSeconds
        : report.periodActiveSeconds;
    final singleDay = report.periodDays == 1;
    final (from, to) = _bounds;
    return PageFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Аналитика', style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 7),
            Text(
              _isDemo
                  ? 'Динамика демонстрационных примеров за 7 дней'
                  : '${shortDate(from)}${from == to ? '' : ' — ${shortDate(to)}'} · данные этого устройства',
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
            const SizedBox(height: Gap.m),
            ModeBadge(mode: report.mode),
            const SizedBox(height: Gap.m),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final range in AnalyticsRange.values)
                  ChoiceChip(
                    label: Text(range.label),
                    selected: _isDemo
                        ? range == AnalyticsRange.last7
                        : range == _range,
                    onSelected: _isDemo ? null : (_) => _selectRange(range),
                  ),
              ],
            ),
            if (_isDemo) ...[
              const SizedBox(height: 6),
              Text(
                'В демо доступен только пример за 7 дней; детализация дня и приложений — в режиме REAL.',
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ],
            const SizedBox(height: Gap.m),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        singleDay
                            ? 'Экранное время по часам'
                            : 'Экранное время по дням',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (!singleDay)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            // Icons only when there is no room for labels.
                            final compact = constraints.maxWidth < 320;
                            return SegmentedButton<_ChartKind>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(
                                  value: _ChartKind.bars,
                                  tooltip: 'Столбцы',
                                  icon: const Icon(
                                    Icons.bar_chart_rounded,
                                    size: 16,
                                  ),
                                  label: compact ? null : const Text('Столбцы'),
                                ),
                                ButtonSegment(
                                  value: _ChartKind.line,
                                  tooltip: 'Линия',
                                  icon: const Icon(
                                    Icons.show_chart_rounded,
                                    size: 16,
                                  ),
                                  label: compact ? null : const Text('Линия'),
                                ),
                              ],
                              selected: {_chart},
                              onSelectionChanged: (v) =>
                                  setState(() => _chart = v.single),
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (singleDay && !_isDemo)
                    HourBars(hours: widget.index!.hourly(to))
                  else if (_chart == _ChartKind.bars) ...[
                    Wrap(
                      spacing: 16,
                      runSpacing: 6,
                      children: [
                        _Legend(
                          color: palette.accent,
                          label: 'В пределах цели',
                        ),
                        _Legend(
                          color: palette.muted.withValues(alpha: .55),
                          label: 'Выше цели',
                        ),
                        _Legend(
                          color: palette.accentSecondary,
                          label: 'Цель ${formatMinutes(report.goalMinutes)}',
                          line: true,
                        ),
                        if (!_isDemo)
                          _Legend(
                            color: palette.border,
                            label: 'Нет данных',
                            outline: true,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    InteractiveBarChart(
                      days: report.days,
                      goalMinutes: report.goalMinutes,
                      onDayTap: _isDemo ? null : (d) => _openDay(d.day),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isDemo ? 'Наведите на столбец, чтобы увидеть значение.' : 'Наведите на столбец, чтобы увидеть значение; нажмите — откроется статистика дня.',
                      style: TextStyle(color: palette.muted, fontSize: 10),
                    ),
                  ] else
                    _LineSection(
                      report: report,
                      index: widget.index,
                      apps: apps,
                      app: _lineApp,
                      compare: _compare,
                      onAppChanged: (v) => setState(() => _lineApp = v),
                      onCompareChanged: (v) => setState(() => _compare = v),
                      onDayTap: _isDemo
                          ? null
                          : (i) => _openDay(report.days[i].day),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Gap.m),
            MetricGrid(
              children: [
                MetricTile(
                  label: 'Всего за период',
                  value: formatDuration(report.periodActiveSeconds),
                  caption: 'дней с данными: $withData из ${report.periodDays}',
                ),
                MetricTile(
                  label: 'В среднем за день',
                  value: formatDuration(report.averageActiveSeconds),
                  caption: 'только дни с данными',
                ),
                MetricTile(
                  label: 'Дней в пределах цели',
                  value: '${report.daysWithinGoal} из $withData',
                  caption: withData == 0
                      ? 'нет данных'
                      : formatPercent(report.daysWithinGoal / withData),
                ),
                MetricTile(
                  label: 'К прошлому периоду',
                  value: change == null
                      ? '—'
                      : '${change <= 0 ? '−' : '+'}${formatPercent(change.abs())}',
                  caption: change == null
                      ? 'нет данных для сравнения'
                      : formatDuration(report.previousActiveSeconds),
                ),
                if (!_isDemo) ...[
                  MetricTile(
                    label: 'Запуски',
                    value: '${report.periodLaunches ?? 0}',
                    caption: 'за период',
                  ),
                  MetricTile(
                    label: 'Бездействие',
                    value: formatDuration(report.periodIdleSeconds),
                    caption: 'без ввода ≥ 2 мин',
                  ),
                ],
              ],
            ),
            const SizedBox(height: Gap.m),
            LayoutBuilder(
              builder: (context, constraints) {
                final appsCard = AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeading(
                        report.appsPeriod == null
                            ? 'Приложения сегодня'
                            : 'Приложения за период',
                      ),
                      const SizedBox(height: 4),
                      if (apps.isEmpty)
                        Text(
                          'За этот период нет данных о приложениях.',
                          style: TextStyle(color: palette.muted, fontSize: 12),
                        ),
                      for (var i = 0; i < apps.length && i < 15; i++)
                        AppUsageTile(
                          app: apps[i],
                          rank: i + 1,
                          totalSeconds: appsTotal,
                          onTap: _isDemo
                              ? null
                              : () => AppDetailScreen.open(
                                  context,
                                  app: apps[i],
                                  from: from,
                                  to: to,
                                  index: widget.index!,
                                  goalMinutes: widget.goalMinutes,
                                ),
                        ),
                      if (_isDemo)
                        Text(
                          'В демо-примере нет разбивки по приложениям за период.',
                          style: TextStyle(color: palette.muted, fontSize: 10),
                        ),
                    ],
                  ),
                );
                final categories = report.categoriesPeriod;
                if (categories == null) return appsCard;
                final donut = AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeading('Категории за неделю'),
                      const SizedBox(height: 10),
                      Center(
                        child: CategoryDonut(
                          minutes: categories,
                          total: report.periodActiveSeconds ~/ 60,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final category in usageCategories)
                        ValueRow(
                          leading: Icon(
                            category.icon,
                            size: 15,
                            color: categoryColorOf(palette, category.id),
                          ),
                          label: category.name,
                          secondary: formatPercent(
                            (categories[category.id] ?? 0) /
                                (report.periodActiveSeconds ~/ 60),
                          ),
                          value: formatMinutes(categories[category.id] ?? 0),
                        ),
                    ],
                  ),
                );
                if (constraints.maxWidth < 760) {
                  return Column(
                    children: [
                      appsCard,
                      const SizedBox(height: Gap.m),
                      donut,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: appsCard),
                    const SizedBox(width: Gap.m),
                    Expanded(flex: 2, child: donut),
                  ],
                );
              },
            ),
            const SizedBox(height: Gap.m),
            _HeatmapCard(
              index: _isDemo ? null : widget.index,
              from: from,
              to: to,
              apps: apps,
              app: _heatApp,
              onAppChanged: (v) => setState(() => _heatApp = v),
            ),
            const SizedBox(height: Gap.m),
            LayoutBuilder(
              builder: (context, constraints) {
                final calendar = StreakCalendar(
                  summary: widget.streak,
                  mode: widget.mode,
                  onDayTap: _isDemo ? null : _openDay,
                );
                final history = StreakHistoryList(
                  summary: widget.streak,
                  mode: widget.mode,
                );
                if (constraints.maxWidth < 720) {
                  return Column(
                    children: [
                      calendar,
                      const SizedBox(height: Gap.m),
                      history,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: calendar),
                    const SizedBox(width: Gap.m),
                    Expanded(child: history),
                  ],
                );
              },
            ),
            if (!_isDemo) ...[
              const SizedBox(height: Gap.m),
              _DailyHistory(report: report),
            ],
          ],
        ),
      ),
    );
  }
}

class _LineSection extends StatelessWidget {
  const _LineSection({
    required this.report,
    required this.index,
    required this.apps,
    required this.app,
    required this.compare,
    required this.onAppChanged,
    required this.onCompareChanged,
    this.onDayTap,
  });

  final UsageReport report;
  final HistoryIndex? index;
  final List<AppTotal> apps;
  final String? app;
  final bool compare;
  final ValueChanged<String?> onAppChanged;
  final ValueChanged<bool> onCompareChanged;
  final ValueChanged<int>? onDayTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final days = report.days;
    final selected = apps.where((a) => a.appId == app).firstOrNull;
    final appDaily = selected == null || index == null
        ? null
        : index!.appDaily(selected.appId, days.first.day, days.last.day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (index != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: selected?.appId,
                  hint: const Text(
                    'Только общее время',
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: onAppChanged,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Только общее время'),
                    ),
                    for (final a in apps.take(30))
                      DropdownMenuItem(
                        value: a.appId,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 190),
                          child: Text(a.name, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                  ],
                ),
              ),
            FilterChip(
              label: const Text('Сравнить с прошлым периодом'),
              selected: compare,
              onSelected: onCompareChanged,
            ),
          ],
        ),
        const SizedBox(height: 8),
        InteractiveLineChart(
          days: [for (final d in days) d.day],
          goalSeconds: report.goalMinutes * 60,
          onDayTap: onDayTap,
          series: [
            ChartSeries(
              label: 'Всего',
              color: palette.accent,
              values: [
                for (final d in days) d.hasData ? d.activeSeconds : null,
              ],
            ),
            if (appDaily != null)
              ChartSeries(
                label: selected!.name,
                color: palette.accentSecondary,
                values: [
                  for (var i = 0; i < days.length; i++)
                    days[i].hasData ? appDaily[i].$2 : null,
                ],
              ),
            if (compare && report.previousDays.length == days.length)
              ChartSeries(
                label: 'Прошлый период',
                color: palette.muted,
                dashed: true,
                values: [
                  for (final d in report.previousDays)
                    d.hasData ? d.activeSeconds : null,
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard({
    required this.index,
    required this.from,
    required this.to,
    required this.apps,
    required this.app,
    required this.onAppChanged,
  });

  final HistoryIndex? index;
  final LocalDay from;
  final LocalDay to;
  final List<AppTotal> apps;
  final String? app;
  final ValueChanged<String?> onAppChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final history = index;
    if (history == null) {
      return const EmptyState(
        icon: Icons.grid_on_rounded,
        title: 'Карта активности доступна в режиме REAL',
        body: 'В демо-примере нет почасовых данных.',
      );
    }
    final selected = apps.any((a) => a.appId == app) ? app : null;
    final map = history.heatmap(from, to, appId: selected);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Карта активности',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: selected,
                  hint: const Text(
                    'Все приложения',
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: onAppChanged,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Все приложения'),
                    ),
                    for (final a in apps.take(30))
                      DropdownMenuItem(
                        value: a.appId,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 190),
                          child: Text(a.name, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (map.isEmpty)
            Text(
              'За выбранный период нет активности для карты.',
              style: TextStyle(color: palette.muted, fontSize: 12),
            )
          else
            ActivityHeatmapView(
              heatmap: map,
              onCellTap: (weekday, hour) =>
                  _showHour(context, history, weekday, hour, selected),
            ),
        ],
      ),
    );
  }

  void _showHour(
    BuildContext context,
    HistoryIndex history,
    int weekday,
    int hour,
    String? appId,
  ) {
    final totals = <String, (String, int)>{};
    var days = 0;
    for (var d = from; !to.isBefore(d); d = d.addDays(1)) {
      if (d.weekday != weekday || (history.day(d).coverageSeconds ?? 0) == 0) {
        continue;
      }
      days++;
      final start = DateTime(d.year, d.month, d.day, hour);
      final end = DateTime(d.year, d.month, d.day, hour + 1);
      for (final s in history.sessionsIn(start, end, appId: appId)) {
        final prev = totals[s.appId];
        totals[s.appId] = (s.appName, (prev?.$2 ?? 0) + s.duration.inSeconds);
      }
    }
    final rows = totals.values.toList()..sort((a, b) => b.$2.compareTo(a.$2));
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${weekdayName(weekday)}, ${hourRange(hour, hour + 1)}'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Сумма за $days дн. со сбором в выбранном периоде.',
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              ),
              const SizedBox(height: 8),
              if (rows.isEmpty) const Text('В этот час активности не было.'),
              for (final (name, seconds) in rows.take(10))
                ValueRow(label: name, value: formatDuration(seconds)),
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
  }
}

/// Per-day totals: the usage history table.
class _DailyHistory extends StatelessWidget {
  const _DailyHistory({required this.report});
  final UsageReport report;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final rows = report.days.reversed.toList();
    return AppCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Three right-aligned columns; narrower and shorter titles on phones.
          final narrow = constraints.maxWidth < 360;
          final column = narrow ? 52.0 : 92.0;
          final titles = narrow
              ? ['Актив.', 'Пауза', 'Сбор']
              : ['Активно', 'Бездействие', 'Сбор'];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeading('История по дням'),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(child: Eyebrow('День')),
                  for (final title in titles)
                    SizedBox(
                      width: column,
                      child: Text(
                        title.toUpperCase(),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .6,
                        ),
                      ),
                    ),
                ],
              ),
              const Divider(height: 16),
              for (final day in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${weekdayShort(day.day.weekday)}, ${day.day.day.toString().padLeft(2, '0')}.${day.day.month.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      for (final value
                          in day.hasData
                              ? [
                                  formatHoursMinutes(day.activeSeconds),
                                  formatHoursMinutes(day.idleSeconds),
                                  formatHoursMinutes(day.coverageSeconds ?? 0),
                                ]
                              : ['—', '—', '—'])
                        SizedBox(
                          width: column,
                          child: Text(
                            value,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              color: day.hasData ? palette.text : palette.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                'Время в формате ч:мм. «Сбор» — сколько REBOOT был запущен и вёл учёт.',
                style: TextStyle(color: palette.muted, fontSize: 10),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    this.line = false,
    this.outline = false,
  });

  final Color color;
  final String label;
  final bool line;
  final bool outline;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: line ? 14 : 9,
        height: line ? 2 : 9,
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
