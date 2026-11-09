import 'package:flutter/material.dart';

import '../models/usage_data.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';
import 'charts.dart';
import 'ui_kit.dart';

/// One app row: rank, monogram, name, share and right-aligned duration.
class AppUsageTile extends StatelessWidget {
  const AppUsageTile({
    super.key,
    required this.app,
    required this.rank,
    required this.totalSeconds,
    this.onTap,
  });

  final AppTotal app;
  final int rank;
  final int totalSeconds;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final category = app.category == null
        ? null
        : usageCategories.firstWhere((c) => c.id == app.category);
    final share = totalSeconds == 0 ? 0.0 : app.activeSeconds / totalSeconds;
    final details = [
      if (category != null) category.name,
      if (app.launches != null) 'запусков: ${app.launches}',
      if (app.sessions != null) 'сессий: ${app.sessions}',
    ].join(' · ');
    return Semantics(
      button: onTap != null,
      label:
          '${app.name}: ${formatDuration(app.activeSeconds)}, ${formatPercent(share)}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 300;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    if (!narrow)
                      SizedBox(
                        width: 22,
                        child: Text(
                          '$rank',
                          style: TextStyle(color: palette.muted, fontSize: 11),
                        ),
                      ),
                    AppMonogram(
                      name: app.name,
                      color: category == null
                          ? null
                          : categoryColorOf(palette, category.id),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (details.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              details,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (!narrow)
                      SizedBox(
                        width: 44,
                        child: Text(
                          formatPercent(share),
                          textAlign: TextAlign.right,
                          style: TextStyle(color: palette.muted, fontSize: 11),
                        ),
                      ),
                    SizedBox(
                      width: narrow ? 78 : 92,
                      child: Text(
                        formatDuration(app.activeSeconds),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onTap != null)
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: palette.muted,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
