import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/usage_data.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';

Color categoryColorOf(RebootPalette palette, UsageCategoryId id) =>
    palette.categoryColors[id.index % palette.categoryColors.length];

class GoalRing extends StatelessWidget {
  const GoalRing({super.key, required this.progress, required this.center});
  final double progress;
  final Widget center;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Выполнение дневной цели: ${(progress * 100).round()} процентов',
    child: ExcludeSemantics(
      child: SizedBox(
        width: 138,
        height: 138,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(138),
              painter: _RingPainter(
                progress,
                track: context.palette.border,
                color: context.palette.accent,
              ),
            ),
            SizedBox(width: 110, height: 110, child: center),
          ],
        ),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.progress, {required this.track, required this.color});
  final double progress;
  final Color track;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    final active = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(7), -math.pi / 2, math.pi * 2, false, base);
    canvas.drawArc(
      rect.deflate(7),
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0, 1),
      false,
      active,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.track != track ||
      oldDelegate.color != color;
}

/// Daily active time as bars on a zero-based scale with a goal line.
/// Days without data are drawn as an outline, never as a zero bar.
class UsageBarChart extends StatelessWidget {
  const UsageBarChart({
    super.key,
    required this.days,
    required this.goalMinutes,
    this.height = 220,
  });

  final List<DayUsage> days;
  final int goalMinutes;
  final double height;

  static String labelFor(DayUsage day, int count, int index) {
    if (count <= 7) return weekdayShort(day.day.weekday);
    final step = count <= 14 ? 2 : 5;
    final fromEnd = count - 1 - index;
    return fromEnd % step == 0 ? '${day.day.day}' : '';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final description = [
      for (final d in days)
        '${d.day.day}.${d.day.month.toString().padLeft(2, '0')}: '
            '${d.hasData ? formatDuration(d.activeSeconds) : 'нет данных'}',
    ].join(', ');
    final style = DefaultTextStyle.of(context).style.copyWith(
      color: palette.muted,
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );
    return Semantics(
      label:
          'График экранного времени по дням. Цель ${formatMinutes(goalMinutes)}. $description',
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: CustomPaint(
            size: Size.infinite,
            painter: _BarChartPainter(
              days: days,
              goalSeconds: goalMinutes * 60,
              palette: palette,
              labelStyle: style,
              labels: [
                for (var i = 0; i < days.length; i++)
                  labelFor(days[i], days.length, i),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarChartPainter extends CustomPainter {
  _BarChartPainter({
    required this.days,
    required this.goalSeconds,
    required this.palette,
    required this.labelStyle,
    required this.labels,
  });

  final List<DayUsage> days;
  final int goalSeconds;
  final RebootPalette palette;
  final TextStyle labelStyle;
  final List<String> labels;

  static const _axisWidth = 34.0, _labelHeight = 22.0, _top = 8.0;

  TextPainter _text(String value) => TextPainter(
    text: TextSpan(text: value, style: labelStyle),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final maxValue = days.fold<int>(
      goalSeconds,
      (m, d) => math.max(m, d.activeSeconds),
    );
    // Nice hour step: 1, 2, 3, 4 or 6 hours.
    final maxHours = math.max(1, (maxValue / 3600).ceil());
    final step = [
      1,
      2,
      3,
      4,
      6,
    ].firstWhere((s) => maxHours / s <= 4, orElse: () => 6);
    final topHours = ((maxHours + step - 1) ~/ step) * step;
    final scaleMax = topHours * 3600.0;
    final plotLeft = _axisWidth;
    final plotWidth = size.width - plotLeft;
    final plotHeight = size.height - _labelHeight - _top;
    double yFor(num seconds) => _top + plotHeight * (1 - seconds / scaleMax);

    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var h = 0; h <= topHours; h += step) {
      final y = yFor(h * 3600);
      canvas.drawLine(Offset(plotLeft, y), Offset(size.width, y), grid);
      final label = _text('$h ч');
      label.paint(
        canvas,
        Offset(plotLeft - label.width - 6, y - label.height / 2),
      );
    }

    final slot = plotWidth / days.length;
    final barWidth = math.min(28.0, slot * .62);
    for (var i = 0; i < days.length; i++) {
      final day = days[i];
      final cx = plotLeft + slot * i + slot / 2;
      final rect = Rect.fromLTRB(
        cx - barWidth / 2,
        yFor(day.activeSeconds),
        cx + barWidth / 2,
        yFor(0),
      );
      if (!day.hasData) {
        final outline = Paint()
          ..color = palette.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(rect.left, yFor(0) - 6, rect.right, yFor(0)),
            const Radius.circular(3),
          ),
          outline,
        );
      } else if (day.activeSeconds > 0) {
        final within = day.activeSeconds <= goalSeconds;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: const Radius.circular(5),
            topRight: const Radius.circular(5),
          ),
          Paint()
            ..color = within
                ? palette.accent
                : palette.muted.withValues(alpha: .55),
        );
      }
      final label = _text(labels[i]);
      label.paint(
        canvas,
        Offset(cx - label.width / 2, size.height - _labelHeight + 6),
      );
    }

    // Dashed goal line.
    final goalY = yFor(goalSeconds);
    final goalPaint = Paint()
      ..color = palette.accentSecondary
      ..strokeWidth = 1.4;
    for (var x = plotLeft; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, goalY),
        Offset(math.min(x + 4, size.width), goalY),
        goalPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter old) =>
      old.days != days ||
      old.goalSeconds != goalSeconds ||
      old.palette != palette ||
      old.labelStyle != labelStyle;
}

class CategoryDonut extends StatelessWidget {
  const CategoryDonut({
    super.key,
    required this.minutes,
    required this.total,
    this.size = 150,
  });
  final Map<UsageCategoryId, int> minutes;
  final int total;
  final double size;
  @override
  Widget build(BuildContext context) {
    final readable = usageCategories
        .map((c) => '${c.name}: ${formatMinutes(minutes[c.id] ?? 0)}')
        .join(', ');
    return Semantics(
      label: 'Распределение по категориям: $readable',
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _DonutPainter(minutes, total, context.palette),
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter(this.minutes, this.total, this.palette);
  final Map<UsageCategoryId, int> minutes;
  final int total;
  final RebootPalette palette;
  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (final item in usageCategories) {
      final sweep = math.pi * 2 * (minutes[item.id] ?? 0) / total;
      canvas.drawArc(
        Offset.zero & size,
        start,
        sweep,
        false,
        Paint()
          ..color = categoryColorOf(palette, item.id)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 17,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.minutes != minutes || old.total != total || old.palette != palette;
}
