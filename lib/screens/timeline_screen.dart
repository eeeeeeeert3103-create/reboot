import 'package:flutter/material.dart';

import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_history.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/interactive_charts.dart';
import '../widgets/ui_kit.dart';
import 'day_detail_screen.dart';

enum _EntryKind { session, idle, locked, gap }

class _Entry {
  _Entry(this.kind, this.start, this.end, [this.session]);
  final _EntryKind kind;
  final DateTime start;
  final DateTime end;
  final AppSession? session;
  Duration get duration => end.difference(start);
}

/// The day as a vertical list: app sessions, idle, lock/sleep and gaps
/// where REBOOT was not collecting. Nothing is filled in.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({
    super.key,
    required this.mode,
    required this.today,
    this.index,
    this.initialDay,
  });

  final UsageDataMode mode;
  final LocalDay today;
  final HistoryIndex? index;
  final LocalDay? initialDay;

  @override
  State<TimelineScreen> createState() => TimelineScreenState();
}

class TimelineScreenState extends State<TimelineScreen> {
  late LocalDay _day = widget.initialDay ?? widget.today;
  String? _app;

  /// Lets other screens open the timeline on a given day.
  void showDay(LocalDay day) => setState(() {
    _day = day;
    _app = null;
  });

  List<_Entry> _entries(HistoryIndex index) {
    final start = DateTime(_day.year, _day.month, _day.day);
    final end = DateTime(_day.year, _day.month, _day.day + 1);
    final entries = <_Entry>[
      for (final s in index.sessionsIn(start, end, appId: _app))
        _Entry(_EntryKind.session, s.start, s.end, s),
      if (_app == null) ...[
        for (final i in index.intervalsIn(start, end, IntervalKind.idle))
          _Entry(_EntryKind.idle, i.start, i.end),
        for (final i in index.intervalsIn(start, end, IntervalKind.locked))
          _Entry(_EntryKind.locked, i.start, i.end),
      ],
    ];
    if (_app == null) {
      // Gaps where nothing was collected.
      final covered = index.intervalsIn(start, end, IntervalKind.coverage);
      var cursor = start.toUtc();
      final now = DateTime.now().toUtc();
      final limit = end.toUtc().isAfter(now) ? now : end.toUtc();
      for (final c in covered) {
        if (c.start.difference(cursor).inMinutes >= 5) {
          entries.add(_Entry(_EntryKind.gap, cursor, c.start));
        }
        if (c.end.isAfter(cursor)) cursor = c.end;
      }
      if (limit.difference(cursor).inMinutes >= 5) {
        entries.add(_Entry(_EntryKind.gap, cursor, limit));
      }
    }
    entries.sort((a, b) => a.start.compareTo(b.start));
    return entries;
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(_day.year, _day.month, _day.day),
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _day = LocalDay.fromDateTime(picked));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final index = widget.index;
    final isReal = widget.mode == UsageDataMode.real && index != null;
    final apps = isReal ? index.apps(_day, _day) : const <AppTotal>[];
    final entries = isReal ? _entries(index) : const <_Entry>[];
    final total = isReal ? index.day(_day).activeSeconds : 0;
    return PageFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Лента дня', style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 7),
            Text(
              'Сессии приложений, бездействие и блокировки по времени.',
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
            const SizedBox(height: Gap.m),
            ModeBadge(mode: widget.mode),
            const SizedBox(height: Gap.m),
            if (!isReal)
              const EmptyState(
                icon: Icons.view_timeline_outlined,
                title: 'Лента доступна только в режиме REAL',
                body: 'В демо-примере нет посекундной истории. Включить сбор можно в Центре приватности.',
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton.outlined(
                    tooltip: 'Предыдущий день',
                    onPressed: () => setState(() => _day = _day.addDays(-1)),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickDay,
                    icon: const Icon(Icons.calendar_today_rounded, size: 16),
                    label: Text(
                      _day == widget.today ? 'Сегодня' : shortDate(_day),
                    ),
                  ),
                  IconButton.outlined(
                    tooltip: 'Следующий день',
                    onPressed: _day.isBefore(widget.today)
                        ? () => setState(() => _day = _day.addDays(1))
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: apps.any((a) => a.appId == _app) ? _app : null,
                      hint: const Text(
                        'Все приложения',
                        overflow: TextOverflow.ellipsis,
                      ),
                      onChanged: (value) => setState(() => _app = value),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Все приложения'),
                        ),
                        for (final a in apps)
                          DropdownMenuItem(
                            value: a.appId,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 190),
                              child: Text(
                                a.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.m),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeading(
                      '${shortDate(_day)} · активно ${formatDuration(total)}',
                    ),
                    const SizedBox(height: 10),
                    HourBars(
                      hours: index.hourly(_day, appId: _app),
                      height: 70,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        _Legend(color: palette.accent, label: 'Приложение'),
                        _Legend(color: palette.warning, label: 'Бездействие'),
                        _Legend(
                          color: palette.muted,
                          label: 'Блокировка или сон',
                        ),
                        _Legend(color: palette.border, label: 'Сбор не шёл'),
                      ],
                    ),
                    const Divider(height: 24),
                    if (entries.isEmpty)
                      Text(
                        'За этот день записей нет.',
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                    for (var i = 0; i < entries.length; i++)
                      _TimelineRow(
                        entry: entries[i],
                        previousApp: _previousApp(entries, i),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _previousApp(List<_Entry> entries, int i) {
    for (var j = i - 1; j >= 0; j--) {
      final s = entries[j].session;
      if (s != null) return s.appName;
      if (entries[j].kind != _EntryKind.session) return null;
    }
    return null;
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.entry, this.previousApp});
  final _Entry entry;
  final String? previousApp;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (color, title) = switch (entry.kind) {
      _EntryKind.session => (palette.accent, entry.session!.appName),
      _EntryKind.idle => (palette.warning, 'Бездействие'),
      _EntryKind.locked => (palette.muted, 'Блокировка или сон'),
      _EntryKind.gap => (palette.border, 'Сбор не шёл'),
    };
    final minutes = entry.duration.inMinutes;
    final barHeight = (24 + minutes * .8).clamp(24, 96).toDouble();
    final switched =
        entry.session != null &&
        previousApp != null &&
        previousApp != entry.session!.appName;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: entry.session == null
          ? null
          : () => showSessionDetails(context, entry.session!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 46,
              child: Text(
                clockTime(entry.start),
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ),
            Container(
              width: 4,
              height: barHeight,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: entry.session == null
                          ? FontWeight.w500
                          : FontWeight.w600,
                      color: entry.kind == _EntryKind.gap
                          ? palette.muted
                          : palette.text,
                    ),
                  ),
                  Text(
                    '${clockTime(entry.start)}–${clockTime(entry.end)}'
                    '${switched ? ' · переход из $previousApp' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.muted, fontSize: 10),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatDuration(entry.duration.inSeconds),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 4, height: 12, color: color),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: context.palette.muted, fontSize: 10)),
    ],
  );
}
