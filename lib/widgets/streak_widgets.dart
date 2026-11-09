import 'package:flutter/material.dart';

import '../models/streak.dart';
import '../models/usage_data.dart';
import '../theme/reboot_themes.dart';
import 'app_card.dart';

String formatDays(int value) {
  final mod10 = value % 10, mod100 = value % 100;
  if (mod10 == 1 && mod100 != 11) return '$value день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$value дня';
  }
  return '$value дней';
}

const _demoNote = 'ДЕМО · не засчитывается';

/// Compact line for the Dashboard header.
class StreakIndicator extends StatelessWidget {
  const StreakIndicator({super.key, required this.summary, required this.mode});
  final StreakSummary summary;
  final UsageDataMode mode;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isDemo = mode == UsageDataMode.demo;
    final label = 'Серия: ${formatDays(summary.current)} в пределах цели';
    return Semantics(
      label: isDemo
          ? '$label. Демонстрационный пример, не засчитывается'
          : label,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: palette.accent.withValues(alpha: .25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.event_available_rounded,
                size: 14,
                color: palette.accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  isDemo ? '$label · $_demoNote' : label,
                  style: TextStyle(
                    color: palette.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Current and best streak plus today's progress toward the daily goal.
class StreakStatsCard extends StatelessWidget {
  const StreakStatsCard({super.key, required this.summary, required this.mode});
  final StreakSummary summary;
  final UsageDataMode mode;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final progress = summary.todayProgress;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Title(mode: mode, title: 'Серия дней в пределах цели'),
          const SizedBox(height: 14),
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              _Stat(label: 'ТЕКУЩАЯ СЕРИЯ', value: formatDays(summary.current)),
              _Stat(label: 'РЕКОРД', value: formatDays(summary.best)),
              _Stat(
                label: 'ДНЕВНАЯ ЦЕЛЬ',
                value: 'до ${formatMinutes(summary.goalMinutes)}',
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (progress == null)
            Text(
              'За сегодня ещё нет данных.',
              style: TextStyle(color: palette.muted, fontSize: 11),
            )
          else ...[
            Text(
              'Сегодня: ${formatMinutes(summary.todayMinutes!)} из ${formatMinutes(summary.goalMinutes)}',
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1).toDouble(),
                minHeight: 6,
                backgroundColor: palette.border,
                color: progress <= 1 ? palette.accent : palette.muted,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            mode == UsageDataMode.demo
                ? 'Пример на демо-данных: эти дни не сохраняются и не засчитываются. '
                      'Реальная серия появится, когда будет подключён сбор статистики устройства.'
                : 'Засчитываются только завершённые дни по данным устройства. '
                      'Сегодняшний день учитывается после его окончания. '
                      'Если день вышел за цель, серия просто начнётся заново.',
            style: TextStyle(color: palette.muted, fontSize: 10, height: 1.45),
          ),
        ],
      ),
    );
  }
}

const _monthNames = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];

/// Month calendar of the streak: within goal, above goal, no data.
/// Monday is the first column; arrows switch months; a tap opens the day.
class StreakCalendar extends StatefulWidget {
  const StreakCalendar({
    super.key,
    required this.summary,
    required this.mode,
    this.onDayTap,
  });
  final StreakSummary summary;
  final UsageDataMode mode;
  final ValueChanged<LocalDay>? onDayTap;

  @override
  State<StreakCalendar> createState() => _StreakCalendarState();
}

class _StreakCalendarState extends State<StreakCalendar> {
  /// Seven days by default; the month grid is one tap away.
  bool _week = true;
  late LocalDay _weekStart = _mondayOf(widget.summary.today);
  late int _year = widget.summary.today.year;
  late int _month = widget.summary.today.month;

  static LocalDay _mondayOf(LocalDay d) => d.addDays(-(d.weekday - 1));

  void _shift(int delta) => setState(() {
    if (_week) {
      _weekStart = _weekStart.addDays(7 * delta);
    } else {
      final m = DateTime(_year, _month + delta);
      _year = m.year;
      _month = m.month;
    }
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final summary = widget.summary;
    final List<LocalDay?> cells;
    final String label;
    final bool atLatest;
    if (_week) {
      cells = [for (var i = 0; i < 7; i++) _weekStart.addDays(i)];
      final end = _weekStart.addDays(6);
      label =
          '${_weekStart.day.toString().padLeft(2, '0')}.${_weekStart.month.toString().padLeft(2, '0')} — '
          '${end.day.toString().padLeft(2, '0')}.${end.month.toString().padLeft(2, '0')}.${end.year}';
      atLatest = !_weekStart.isBefore(_mondayOf(summary.today));
    } else {
      final first = LocalDay(_year, _month, 1);
      final daysInMonth = DateTime(_year, _month + 1, 0).day;
      final leading = first.weekday - 1;
      final count = ((leading + daysInMonth) / 7).ceil() * 7;
      cells = [
        for (var i = 0; i < count; i++)
          i < leading || i - leading >= daysInMonth
              ? null
              : LocalDay(_year, _month, i - leading + 1),
      ];
      label = '${_monthNames[_month - 1]} $_year';
      atLatest = _year == summary.today.year && _month == summary.today.month;
    }
    final shown = cells
        .whereType<LocalDay>()
        .map(summary.dayFor)
        .whereType<StreakDay>();
    final met = shown.where((d) => d.goalMet).length;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Title(mode: widget.mode, title: 'Календарь серии'),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('7 дней')),
                  ButtonSegment(value: false, label: Text('Месяц')),
                ],
                selected: {_week},
                onSelectionChanged: (v) => setState(() {
                  _week = v.single;
                  _weekStart = _mondayOf(summary.today);
                  _year = summary.today.year;
                  _month = summary.today.month;
                }),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              IconButton(
                tooltip: _week ? 'Предыдущая неделя' : 'Предыдущий месяц',
                visualDensity: VisualDensity.compact,
                onPressed: () => _shift(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: _week ? 'Следующая неделя' : 'Следующий месяц',
                visualDensity: VisualDensity.compact,
                onPressed: atLatest ? null : () => _shift(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var weekday = 1; weekday <= 7; weekday++)
                Expanded(
                  child: Center(
                    child: Text(
                      weekdayShort(weekday),
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (var row = 0; row < cells.length ~/ 7; row++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: cells[row * 7 + col] == null
                        ? const AspectRatio(aspectRatio: 1, child: SizedBox())
                        : _DayCell(
                            day: cells[row * 7 + col]!,
                            summary: summary,
                            onTap: widget.onDayTap,
                          ),
                  ),
              ],
            ),
          if (_week)
            Row(
              children: [
                for (final day in cells.whereType<LocalDay>())
                  Expanded(
                    child: Text(
                      summary.dayFor(day) == null
                          ? '—'
                          : formatHoursMinutesFromMinutes(
                              summary.dayFor(day)!.minutes,
                            ),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.muted, fontSize: 10),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 10),
          Text(
            '${_week ? 'За неделю' : 'В этом месяце'}: в пределах цели $met из ${shown.length} дн. с полными данными',
            style: TextStyle(color: palette.muted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _LegendDot(
                color: palette.accent.withValues(alpha: .75),
                label: 'В пределах цели',
              ),
              _LegendDot(
                color: palette.muted.withValues(alpha: .35),
                label: 'Выше цели',
              ),
              _LegendDot(
                color: Colors.transparent,
                border: palette.border,
                label: 'Нет полных данных',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String formatHoursMinutesFromMinutes(int minutes) =>
    '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.summary, this.onTap});
  final LocalDay day;
  final StreakSummary summary;
  final ValueChanged<LocalDay>? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final record = summary.dayFor(day);
    final isToday = day == summary.today;
    final isFuture = summary.today.isBefore(day);
    final Color fill;
    final String state;
    if (record == null) {
      fill = Colors.transparent;
      state = isToday
          ? 'сегодня, день ещё идёт'
          : (isFuture ? 'ещё не наступил' : 'нет полных данных');
    } else if (record.goalMet) {
      fill = palette.accent.withValues(alpha: .75);
      state = 'в пределах цели, ${formatMinutes(record.minutes)}';
    } else {
      fill = palette.muted.withValues(alpha: .35);
      state = 'выше цели, ${formatMinutes(record.minutes)}';
    }
    return Semantics(
      button: onTap != null && !isFuture,
      label: '${day.day}.${day.month.toString().padLeft(2, '0')}: $state',
      child: ExcludeSemantics(
        child: Tooltip(
          message: state,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap == null || isFuture ? null : () => onTap!(day),
            child: Padding(
              padding: const EdgeInsets.all(2.5),
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isToday ? palette.accent : palette.border,
                      width: isToday ? 1.5 : 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: 10,
                      color: isFuture ? palette.border : palette.text,
                      fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Most recent completed days, newest first.
class StreakHistoryList extends StatelessWidget {
  const StreakHistoryList({
    super.key,
    required this.summary,
    required this.mode,
    this.limit = 7,
  });
  final StreakSummary summary;
  final UsageDataMode mode;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final items = summary.history.reversed.take(limit).toList();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Title(mode: mode, title: 'История дней'),
          const SizedBox(height: 8),
          if (items.isEmpty)
            Text(
              'Пока нет завершённых дней с данными.',
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Icon(
                    item.goalMet
                        ? Icons.check_circle_outline_rounded
                        : Icons.remove_circle_outline_rounded,
                    size: 16,
                    color: item.goalMet ? palette.accent : palette.muted,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${weekdayShort(item.day.weekday)}, '
                    '${item.day.day.toString().padLeft(2, '0')}.'
                    '${item.day.month.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${formatMinutes(item.minutes)} · '
                      '${item.goalMet ? 'в пределах цели' : 'выше цели'}',
                      textAlign: TextAlign.end,
                      style: TextStyle(color: palette.muted, fontSize: 11),
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

class _Title extends StatelessWidget {
  const _Title({required this.mode, required this.title});
  final UsageDataMode mode;
  final String title;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      if (mode == UsageDataMode.demo)
        Text(
          _demoNote,
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: .5,
          ),
        ),
    ],
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: context.palette.muted,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: .5,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
      ),
    ],
  );
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label, this.border});
  final Color color;
  final Color? border;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
          border: border == null ? null : Border.all(color: border!),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: context.palette.muted, fontSize: 10)),
    ],
  );
}
