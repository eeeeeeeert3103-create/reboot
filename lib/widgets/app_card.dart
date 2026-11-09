import 'package:flutter/material.dart';

import '../theme/reboot_themes.dart';

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? context.palette.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: context.palette.border.withValues(alpha: .8)),
    ),
    child: child,
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      if (action != null)
        TextButton(
          onPressed: onAction,
          child: Text(action!, style: TextStyle(color: context.palette.accent)),
        ),
    ],
  );
}

class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 9 : 12,
      vertical: compact ? 6 : 8,
    ),
    decoration: BoxDecoration(
      color: context.palette.muted.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: context.palette.muted.withValues(alpha: .2)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: context.palette.muted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          'ДЕМО-ДАННЫЕ',
          style: TextStyle(
            color: context.palette.muted,
            fontSize: compact ? 9 : 10,
            fontWeight: FontWeight.w700,
            letterSpacing: .6,
          ),
        ),
      ],
    ),
  );
}

class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.child, this.maxWidth = 1120});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    ),
  );
}
