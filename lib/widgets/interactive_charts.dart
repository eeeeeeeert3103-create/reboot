import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/insights.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';

String shortDate(LocalDay d) =>
    '${weekdayShort(d.weekday)}, ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

/// Hour scale with a "nice" step that covers [maxSeconds].
({int step, int top}) _hourScale(int maxSeconds) {
  final maxHours = math.max(1, (maxSeconds / 3600).ceil());
  final step = [
    1,
    2,
    3,
    4,
    6,
    12,
  ].firstWhere((s) => maxHours / s <= 4, orElse: () => 12);
  return (step: step, top: ((maxHours + step - 1) ~/ step) * step);
}

class _Tooltip extends StatelessWidget {
  const _Tooltip({required this.lines});
  final List<(String, String, Color?)> lines;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: palette.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.border),
          boxShadow: const [
            BoxShadow(blurRadius: 12, color: Color(0x33000000)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value, color) in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (color != null) ...[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _positionedTooltip({
  required double x,
  required double width,
  required Widget child,
}) {
  const tooltipWidth = 220.0;
  final left = (x - tooltipWidth / 2).clamp(
    0.0,
    math.max(0.0, width - tooltipWidth),
  );
  return Positioned(
    left: left.toDouble(),
    top: 0,
    width: tooltipWidth,
    child: child,
  );
}

// ---------------------------------------------------------------------------
// Bar chart

/// Daily bars on a zero-based hour scale with a dashed goal line.
/// Hover or tap shows the exact value; [onDayTap] opens the day.
class InteractiveBarChart extends StatefulWidget {
  const InteractiveBarChart({
    super.key,
    required this.days,
    required this.goalMinutes,
    this.onDayTap,
    this.height = 240,
  });

  final List<DayUsage> days;
  final int goalMinutes;
  final ValueChanged<DayUsage>? onDayTap;
  final double height;

  @override
  State<InteractiveBarChart> createState() => _InteractiveBarChartState();
}

class _InteractiveBarChartState extends State<InteractiveBarChart> {
  int? _hover;

  static const _axis = 34.0, _labels = 22.0, _top = 50.0;

  int? _indexAt(Offset p, double width) {
    if (widget.days.isEmpty || p.dx < _axis) return null;
    final slot = (width - _axis) / widget.days.length;
    final i = ((p.dx - _axis) / slot).floor();
    return i >= 0 && i < widget.days.length ? i : null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final days = widget.days;
    final description = [
      for (final d in days)
        '${shortDate(d.day)}: ${d.hasData ? formatDuration(d.activeSeconds) : 'нет данных'}',
    ].join(', ');
    return Semantics(
      label:
          'График экранного времени по дням. Цель ${formatMinutes(widget.goalMinutes)}. $description',
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final hover = _hover;
            final slot = days.isEmpty ? 0.0 : (width - _axis) / days.length;
            return MouseRegion(
              cursor: widget.onDayTap == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              onHover: (e) =>
                  setState(() => _hover = _indexAt(e.localPosition, width)),
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (e) {
                  final i = _indexAt(e.localPosition, width);
                  if (i == null) return;
                  setState(() => _hover = i);
                  widget.onDayTap?.call(days[i]);
                },
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _BarsPainter(
                          days: days,
                          goalSeconds: widget.goalMinutes * 60,
                          palette: palette,
                          highlight: hover,
                          labelStyle: DefaultTextStyle.of(context).style
                              .copyWith(
                                color: palette.muted,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ),
                    if (hover != null)
                      _positionedTooltip(
                        x: _axis + slot * hover + slot / 2,
                        width: width,
                        child: _Tooltip(
                          lines: [
                            (shortDate(days[hover].day), '', null),
                            (
                              'Экранное время',
                              days[hover].hasData
                                  ? formatDuration(days[hover].activeSeconds)
                                  : 'нет данных',
                              null,
                            ),
                            if (days[hover].hasData)
                              (
                                'Цель',
                                days[hover].activeSeconds <=
                                        widget.goalMinutes * 60
                                    ? 'в пределах'
                                    : 'выше на ${formatDuration(days[hover].activeSeconds - widget.goalMinutes * 60)}',
                                null,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.days,
    required this.goalSeconds,
    required this.palette,
    required this.highlight,
    required this.labelStyle,
  });

  final List<DayUsage> days;
  final int goalSeconds;
  final RebootPalette palette;
  final int? highlight;
  final TextStyle labelStyle;

  TextPainter _text(String v) => TextPainter(
    text: TextSpan(text: v, style: labelStyle),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    const axis = _InteractiveBarChartState._axis;
    const labels = _InteractiveBarChartState._labels;
    const top = _InteractiveBarChartState._top;
    final maxValue = days.fold<int>(
      goalSeconds,
      (m, d) => math.max(m, d.activeSeconds),
    );
    final scale = _hourScale(maxValue);
    final plotHeight = size.height - labels - top;
    double y(num seconds) =>
        top + plotHeight * (1 - seconds / (scale.top * 3600));
    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var h = 0; h <= scale.top; h += scale.step) {
      canvas.drawLine(
        Offset(axis, y(h * 3600)),
        Offset(size.width, y(h * 3600)),
        grid,
      );
      final t = _text('$h ч');
      t.paint(canvas, Offset(axis - t.width - 6, y(h * 3600) - t.height / 2));
    }
    final slot = (size.width - axis) / days.length;
    final barWidth = math.min(26.0, slot * .62);
    final labelEvery = days.length <= 7
        ? 1
        : (days.length <= 14 ? 2 : (days.length <= 31 ? 5 : 10));
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      final cx = axis + slot * i + slot / 2;
      if (i == highlight) {
        canvas.drawRect(
          Rect.fromLTRB(axis + slot * i, top, axis + slot * (i + 1), y(0)),
          Paint()..color = palette.accent.withValues(alpha: .08),
        );
      }
      if (!d.hasData) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(cx - barWidth / 2, y(0) - 6, cx + barWidth / 2, y(0)),
            const Radius.circular(3),
          ),
          Paint()
            ..color = palette.border
            ..style = PaintingStyle.stroke,
        );
      } else if (d.activeSeconds > 0) {
        final within = d.activeSeconds <= goalSeconds;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(
              cx - barWidth / 2,
              y(d.activeSeconds),
              cx + barWidth / 2,
              y(0),
            ),
            topLeft: const Radius.circular(5),
            topRight: const Radius.circular(5),
          ),
          Paint()
            ..color = within
                ? palette.accent.withValues(alpha: i == highlight ? 1 : .85)
                : palette.muted.withValues(alpha: i == highlight ? .8 : .55),
        );
      }
      final fromEnd = days.length - 1 - i;
      final label = days.length <= 7
          ? weekdayShort(d.day.weekday)
          : (fromEnd % labelEvery == 0 ? '${d.day.day}' : '');
      if (label.isNotEmpty) {
        final t = _text(label);
        t.paint(canvas, Offset(cx - t.width / 2, size.height - labels + 6));
      }
    }
    final goalY = y(goalSeconds);
    final goalPaint = Paint()
      ..color = palette.accentSecondary
      ..strokeWidth = 1.4;
    for (var x = axis; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, goalY),
        Offset(math.min(x + 4, size.width), goalY),
        goalPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old.days != days ||
      old.goalSeconds != goalSeconds ||
      old.palette != palette ||
      old.highlight != highlight ||
      old.labelStyle != labelStyle;
}

// ---------------------------------------------------------------------------
// Line chart

class ChartSeries {
  const ChartSeries({
    required this.label,
    required this.values,
    required this.color,
    this.dashed = false,
  });

  final String label;

  /// Seconds per point; `null` means "no data" and breaks the line.
  final List<int?> values;
  final Color color;
  final bool dashed;
}

/// Multi-series line chart over days with hover tooltip, tap to pin a point,
/// mouse-wheel / button zoom and drag to pan.
class InteractiveLineChart extends StatefulWidget {
  const InteractiveLineChart({
    super.key,
    required this.days,
    required this.series,
    this.goalSeconds,
    this.height = 260,
    this.onDayTap,
  });

  final List<LocalDay> days;
  final List<ChartSeries> series;
  final int? goalSeconds;
  final double height;
  final ValueChanged<int>? onDayTap;

  @override
  State<InteractiveLineChart> createState() => _InteractiveLineChartState();
}

class _InteractiveLineChartState extends State<InteractiveLineChart> {
  int _start = 0;
  late int _end = widget.days.length;
  int? _hover;
  int? _pinned;
  double _dragCarry = 0;

  static const _axis = 34.0, _labels = 22.0, _top = 8.0;

  @override
  void didUpdateWidget(covariant InteractiveLineChart old) {
    super.didUpdateWidget(old);
    if (old.days.length != widget.days.length) {
      _start = 0;
      _end = widget.days.length;
      _hover = null;
      _pinned = null;
    }
  }

  int get _visible => _end - _start;
  bool get _zoomed => _start > 0 || _end < widget.days.length;

  void _zoom(double factor, {double anchor = .5}) {
    final n = widget.days.length;
    if (n < 2) return;
    final int target = (_visible * factor).round().clamp(math.min(3, n), n);
    final center = _start + _visible * anchor;
    var start = (center - target * anchor).round();
    start = start.clamp(0, n - target).toInt();
    setState(() {
      _start = start;
      _end = start + target;
    });
  }

  void _pan(int delta) {
    final n = widget.days.length;
    final start = (_start + delta).clamp(0, n - _visible);
    setState(() {
      _end = start + _visible;
      _start = start;
    });
  }

  int? _indexAt(Offset p, double width) {
    if (_visible <= 0 || p.dx < _axis) return null;
    final step = _visible <= 1 ? 0.0 : (width - _axis) / (_visible - 1);
    final i = step == 0 ? 0 : ((p.dx - _axis) / step).round();
    return i >= 0 && i < _visible ? _start + i : null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final days = widget.days;
    final shown = _pinned ?? _hover;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                days.isEmpty
                    ? ''
                    : '${shortDate(days[_start])} — ${shortDate(days[_end - 1])}',
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ),
            IconButton(
              tooltip: 'Приблизить',
              visualDensity: VisualDensity.compact,
              onPressed: _visible > 3 ? () => _zoom(.6) : null,
              icon: const Icon(Icons.zoom_in_rounded, size: 18),
            ),
            IconButton(
              tooltip: 'Отдалить',
              visualDensity: VisualDensity.compact,
              onPressed: _zoomed ? () => _zoom(1.6) : null,
              icon: const Icon(Icons.zoom_out_rounded, size: 18),
            ),
            IconButton(
              tooltip: 'Показать весь период',
              visualDensity: VisualDensity.compact,
              onPressed: _zoomed
                  ? () => setState(() {
                      _start = 0;
                      _end = days.length;
                    })
                  : null,
              icon: const Icon(Icons.fit_screen_rounded, size: 18),
            ),
          ],
        ),
        SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final step = _visible <= 1
                  ? 0.0
                  : (width - _axis) / (_visible - 1);
              return Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    final anchor =
                        ((event.localPosition.dx - _axis) / (width - _axis))
                            .clamp(0.0, 1.0);
                    _zoom(event.scrollDelta.dy > 0 ? 1.25 : .8, anchor: anchor);
                  }
                },
                child: MouseRegion(
                  onHover: (e) =>
                      setState(() => _hover = _indexAt(e.localPosition, width)),
                  onExit: (_) => setState(() => _hover = null),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (e) {
                      final i = _indexAt(e.localPosition, width);
                      setState(() => _pinned = i == _pinned ? null : i);
                      if (i != null) widget.onDayTap?.call(i);
                    },
                    onHorizontalDragUpdate: _zoomed
                        ? (d) {
                            if (step == 0) return;
                            _dragCarry -= d.delta.dx / step;
                            final whole = _dragCarry.truncate();
                            if (whole != 0) {
                              _dragCarry -= whole;
                              _pan(whole);
                            }
                          }
                        : null,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _LinePainter(
                              days: days,
                              series: widget.series,
                              start: _start,
                              end: _end,
                              goalSeconds: widget.goalSeconds,
                              highlight: shown,
                              palette: palette,
                              labelStyle: DefaultTextStyle.of(context).style
                                  .copyWith(
                                    color: palette.muted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ),
                        if (shown != null)
                          _positionedTooltip(
                            x: _axis + step * (shown - _start),
                            width: width,
                            child: _Tooltip(
                              lines: [
                                (shortDate(days[shown]), '', null),
                                for (final s in widget.series)
                                  (
                                    s.label,
                                    s.values[shown] == null
                                        ? 'нет данных'
                                        : formatDuration(s.values[shown]!),
                                    s.color,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final s in widget.series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 14, height: 3, color: s.color),
                  const SizedBox(width: 6),
                  Text(
                    s.label,
                    style: TextStyle(color: palette.muted, fontSize: 10),
                  ),
                ],
              ),
            Text(
              'Колесо мыши или кнопки — масштаб, перетаскивание — сдвиг, нажатие — закрепить точку',
              style: TextStyle(color: palette.muted, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.days,
    required this.series,
    required this.start,
    required this.end,
    required this.goalSeconds,
    required this.highlight,
    required this.palette,
    required this.labelStyle,
  });

  final List<LocalDay> days;
  final List<ChartSeries> series;
  final int start, end;
  final int? goalSeconds;
  final int? highlight;
  final RebootPalette palette;
  final TextStyle labelStyle;

  TextPainter _text(String v) => TextPainter(
    text: TextSpan(text: v, style: labelStyle),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final visible = end - start;
    if (visible <= 0) return;
    const axis = _InteractiveLineChartState._axis;
    const labels = _InteractiveLineChartState._labels;
    const top = _InteractiveLineChartState._top;
    var maxValue = goalSeconds ?? 0;
    for (final s in series) {
      for (var i = start; i < end; i++) {
        maxValue = math.max(maxValue, s.values[i] ?? 0);
      }
    }
    final scale = _hourScale(maxValue);
    final plotHeight = size.height - labels - top;
    double y(num seconds) =>
        top + plotHeight * (1 - seconds / (scale.top * 3600));
    final step = visible <= 1 ? 0.0 : (size.width - axis) / (visible - 1);
    double x(int i) => axis + step * (i - start);
    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var h = 0; h <= scale.top; h += scale.step) {
      canvas.drawLine(
        Offset(axis, y(h * 3600)),
        Offset(size.width, y(h * 3600)),
        grid,
      );
      final t = _text('$h ч');
      t.paint(canvas, Offset(axis - t.width - 6, y(h * 3600) - t.height / 2));
    }
    if (goalSeconds != null) {
      final paint = Paint()
        ..color = palette.accentSecondary.withValues(alpha: .7)
        ..strokeWidth = 1.2;
      for (var px = axis; px < size.width; px += 8) {
        canvas.drawLine(
          Offset(px, y(goalSeconds!)),
          Offset(math.min(px + 4, size.width), y(goalSeconds!)),
          paint,
        );
      }
    }
    if (highlight != null && highlight! >= start && highlight! < end) {
      canvas.drawLine(
        Offset(x(highlight!), top),
        Offset(x(highlight!), y(0)),
        Paint()
          ..color = palette.muted.withValues(alpha: .5)
          ..strokeWidth = 1,
      );
    }
    for (final s in series) {
      final paint = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.dashed ? 1.6 : 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      Path? path;
      for (var i = start; i < end; i++) {
        final v = s.values[i];
        if (v == null) {
          if (path != null) canvas.drawPath(path, paint);
          path = null;
          continue;
        }
        final p = Offset(x(i), y(v));
        if (path == null) {
          path = Path()..moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
        if (!s.dashed) {
          canvas.drawCircle(
            p,
            i == highlight ? 4.5 : 2.6,
            Paint()..color = s.color,
          );
        }
      }
      if (path != null) {
        if (s.dashed) {
          for (final metric in path.computeMetrics()) {
            for (double d = 0; d < metric.length; d += 9) {
              canvas.drawPath(
                metric.extractPath(d, math.min(d + 5, metric.length)),
                paint,
              );
            }
          }
        } else {
          canvas.drawPath(path, paint);
        }
      }
    }
    final every = math.max(1, (visible / 7).ceil());
    for (var i = start; i < end; i++) {
      if ((end - 1 - i) % every != 0) continue;
      final label = visible <= 7
          ? weekdayShort(days[i].weekday)
          : '${days[i].day}.${days[i].month.toString().padLeft(2, '0')}';
      final t = _text(label);
      final px = (x(i) - t.width / 2).clamp(axis, size.width - t.width);
      t.paint(canvas, Offset(px, size.height - labels + 6));
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

// ---------------------------------------------------------------------------
// Heatmap

/// Weekday × hour grid. Colour shows average active minutes per covered day.
class ActivityHeatmapView extends StatefulWidget {
  const ActivityHeatmapView({super.key, required this.heatmap, this.onCellTap});

  final ActivityHeatmap heatmap;

  /// Called with weekday (1–7) and hour (0–23).
  final void Function(int weekday, int hour)? onCellTap;

  @override
  State<ActivityHeatmapView> createState() => _ActivityHeatmapViewState();
}

class _ActivityHeatmapViewState extends State<ActivityHeatmapView> {
  (int, int)? _hover;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final map = widget.heatmap;
    var maxAverage = 0;
    for (var w = 0; w < 7; w++) {
      for (var h = 0; h < 24; h++) {
        maxAverage = math.max(maxAverage, map.average(w, h));
      }
    }
    const labelWidth = 26.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 24 cells plus 1.5 px margins must fit exactly into the width.
        final cell = ((constraints.maxWidth - labelWidth) / 24 - 1.5).clamp(
          2.0,
          28.0,
        );
        final hover = _hover;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 18,
              child: hover == null
                  ? Text(
                      'Наведите на ячейку: среднее за день недели, только дни со сбором',
                      style: TextStyle(color: palette.muted, fontSize: 10),
                    )
                  : Text(
                      '${weekdayName(hover.$1 + 1)}, ${hourRange(hover.$2, hover.$2 + 1)}: '
                      '${formatDuration(map.average(hover.$1, hover.$2))} в среднем · '
                      'дней: ${map.coveredDays[hover.$1]}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            const SizedBox(height: 6),
            for (var w = 0; w < 7; w++)
              Row(
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Text(
                      weekdayShort(w + 1),
                      style: TextStyle(color: palette.muted, fontSize: 9),
                    ),
                  ),
                  for (var h = 0; h < 24; h++)
                    MouseRegion(
                      cursor: widget.onCellTap == null
                          ? MouseCursor.defer
                          : SystemMouseCursors.click,
                      onEnter: (_) => setState(() => _hover = (w, h)),
                      onExit: (_) => setState(() => _hover = null),
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _hover = (w, h));
                          widget.onCellTap?.call(w + 1, h);
                        },
                        child: Container(
                          width: cell,
                          height: cell,
                          margin: const EdgeInsets.all(.75),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2.5),
                            color: map.coveredDays[w] == 0
                                ? Colors.transparent
                                : maxAverage == 0
                                ? palette.surfaceRaised
                                : Color.lerp(
                                    palette.surfaceRaised,
                                    palette.accent,
                                    math.sqrt(map.average(w, h) / maxAverage),
                                  ),
                            border: Border.all(
                              color: hover == (w, h)
                                  ? palette.text
                                  : palette.border.withValues(alpha: .5),
                              width: hover == (w, h) ? 1.2 : .5,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: labelWidth),
                for (final h in [0, 6, 12, 18])
                  SizedBox(
                    width: (cell + 1.5) * 6,
                    child: Text(
                      '${h.toString().padLeft(2, '0')}:00',
                      style: TextStyle(color: palette.muted, fontSize: 9),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
