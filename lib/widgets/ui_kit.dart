import 'package:flutter/material.dart';

import '../models/streak.dart';
import '../theme/reboot_themes.dart';
import 'app_card.dart';

/// Shared spacing so every screen sits on the same grid.
abstract final class Gap {
  static const xs = 4.0, s = 8.0, m = 14.0, l = 22.0, xl = 32.0;
}

/// Says where the numbers come from. Shown on every data screen.
class ModeBadge extends StatelessWidget {
  const ModeBadge({super.key, required this.mode, this.compact = false});
  final UsageDataMode mode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final real = mode == UsageDataMode.real;
    final color = real ? palette.success : palette.muted;
    return Semantics(
      label: real ? 'Данные этого устройства' : 'Демонстрационные данные',
      child: ExcludeSemantics(
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 9 : 12,
            vertical: compact ? 6 : 8,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .09),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: color.withValues(alpha: .25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(
                real ? 'ДАННЫЕ УСТРОЙСТВА' : 'ДЕМО-ДАННЫЕ',
                style: TextStyle(
                  color: color,
                  fontSize: compact ? 9 : 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small caps label used above values.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: color ?? context.palette.muted,
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: .8,
    ),
  );
}

/// A label, a large value and an optional caption.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.icon,
  });

  final String label;
  final String value;
  final String? caption;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: '$label: $value${caption == null ? '' : ', $caption'}',
      child: ExcludeSemantics(
        child: AppCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: palette.accent),
                    const SizedBox(width: 6),
                  ],
                  Expanded(child: Eyebrow(label)),
                ],
              ),
              const SizedBox(height: 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.3,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                caption ?? ' ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays out tiles in equal columns; every tile in a row has the same size.
class MetricGrid extends StatelessWidget {
  const MetricGrid({super.key, required this.children, this.maxColumns = 4});
  final List<Widget> children;
  final int maxColumns;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = (width / 190).floor().clamp(1, maxColumns);
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i += columns) {
        final slice = children.sublist(
          i,
          (i + columns).clamp(0, children.length),
        );
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < columns; j++) ...[
                  if (j > 0) const SizedBox(width: Gap.m),
                  Expanded(
                    child: j < slice.length ? slice[j] : const SizedBox(),
                  ),
                ],
              ],
            ),
          ),
        );
      }
      return Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: Gap.m),
            rows[i],
          ],
        ],
      );
    },
  );
}

/// An honest placeholder for missing data, errors or unavailable features.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: palette.accent, size: 20),
          const SizedBox(width: 12),
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
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                if (action != null && onAction != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onAction,
                    child: Text(action!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A row with a label on the left and a right-aligned tabular value.
class ValueRow extends StatelessWidget {
  const ValueRow({
    super.key,
    required this.label,
    required this.value,
    this.leading,
    this.secondary,
  });

  final String label;
  final String value;
  final Widget? leading;
  final String? secondary;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 10)],
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        if (secondary != null) ...[
          const SizedBox(width: 10),
          Text(
            secondary!,
            textAlign: TextAlign.right,
            style: TextStyle(color: context.palette.muted, fontSize: 11),
          ),
        ],
        const SizedBox(width: 12),
        Text(
          value,
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

/// Neutral avatar for real apps: REBOOT does not read app icons.
class AppMonogram extends StatelessWidget {
  const AppMonogram({super.key, required this.name, this.color, this.icon});
  final String name;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.palette.accentSecondary;
    final letter = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: icon != null
          ? Icon(icon, size: 17, color: tint)
          : Text(
              letter,
              style: TextStyle(
                color: tint,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
    );
  }
}
