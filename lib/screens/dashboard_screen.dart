import 'package:flutter/material.dart';

import '../models/collector_models.dart';
import '../models/streak.dart';
import '../models/usage_data.dart';
import '../models/usage_report.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/app_usage_tile.dart';
import '../widgets/charts.dart';
import '../widgets/streak_widgets.dart';
import '../widgets/ui_kit.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.displayName,
    required this.report,
    required this.streak,
    this.status,
    this.onOpenPrivacy,
  });

  final String displayName;
  final UsageReport report;
  final StreakSummary streak;
  final CollectorStatus? status;
  final VoidCallback? onOpenPrivacy;

  bool get _isDemo => report.mode == UsageDataMode.demo;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final today = report.todayUsage;
    final yesterday = report.yesterdayUsage;
    final noDemoValue = today.coverageSeconds == null;
    return PageFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Eyebrow(formattedDate),
                ModeBadge(mode: report.mode, compact: true),
                StreakIndicator(summary: streak, mode: report.mode),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'С возвращением,\n$displayName',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: Gap.l),
            if (!_isDemo && !report.hasAnyData) ...[
              EmptyState(
                icon: Icons.hourglass_top_rounded,
                title: 'Данных за сегодня пока нет',
                body:
                    '${status?.message ?? 'Сбор статистики включён.'} '
                    'Первые значения появятся после ближайшей синхронизации (до 30 секунд).',
              ),
              const SizedBox(height: Gap.m),
            ],
            if (_isDemo) ...[
              EmptyState(
                icon: Icons.science_outlined,
                title: 'Вы смотрите демонстрационный пример',
                body:
                    'Значения подготовлены заранее и не получены с устройства. '
                    'Включить сбор реальной статистики можно в Центре приватности.',
                action: onOpenPrivacy == null
                    ? null
                    : 'Открыть Центр приватности',
                onAction: onOpenPrivacy,
              ),
              const SizedBox(height: Gap.m),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final summary = _TodaySummary(
                  report: report,
                  today: today,
                  yesterday: yesterday,
                );
                final streakCard = StreakStatsCard(
                  summary: streak,
                  mode: report.mode,
                );
                if (constraints.maxWidth < 760) {
                  return Column(
                    children: [
                      summary,
                      const SizedBox(height: Gap.m),
                      streakCard,
                    ],
                  );
                }
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 6, child: summary),
                      const SizedBox(width: Gap.m),
                      Expanded(flex: 5, child: streakCard),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: Gap.m),
            MetricGrid(
              children: [
                MetricTile(
                  label: 'Запуски приложений',
                  icon: Icons.rocket_launch_outlined,
                  value: today.launches?.toString() ?? '—',
                  caption: noDemoValue ? 'нет в демо-данных' : 'сегодня',
                ),
                MetricTile(
                  label: 'Разблокировки',
                  icon: Icons.lock_open_rounded,
                  value: today.unlocks?.toString() ?? '—',
                  caption: noDemoValue
                      ? 'нет в демо-данных'
                      : 'включая пробуждение',
                ),
                MetricTile(
                  label: 'Бездействие',
                  icon: Icons.pause_circle_outline_rounded,
                  value: noDemoValue ? '—' : formatDuration(today.idleSeconds),
                  caption: noDemoValue
                      ? 'нет в демо-данных'
                      : 'без ввода ≥ 2 мин',
                ),
                MetricTile(
                  label: 'Сбор шёл',
                  icon: Icons.sensors_rounded,
                  value: noDemoValue
                      ? '—'
                      : formatDuration(today.coverageSeconds!),
                  caption: noDemoValue
                      ? 'нет в демо-данных'
                      : 'пока REBOOT был запущен',
                ),
              ],
            ),
            const SizedBox(height: Gap.m),
            LayoutBuilder(
              builder: (context, constraints) {
                final apps = _TopApps(report: report);
                final categories = report.categoriesToday;
                if (categories == null) return apps;
                final categoryCard = _Categories(
                  minutes: categories,
                  total: today.activeMinutes,
                );
                if (constraints.maxWidth < 700) {
                  return Column(
                    children: [
                      categoryCard,
                      const SizedBox(height: Gap.m),
                      apps,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: categoryCard),
                    const SizedBox(width: Gap.m),
                    Expanded(child: apps),
                  ],
                );
              },
            ),
            const SizedBox(height: Gap.m),
            Center(
              child: Text(
                _isDemo
                    ? 'Демонстрационный пример · статистика не получена с устройства'
                    : 'Учитывается только активное приложение, пока REBOOT запущен. Данные хранятся только на этом устройстве.',
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

class _TodaySummary extends StatelessWidget {
  const _TodaySummary({
    required this.report,
    required this.today,
    required this.yesterday,
  });

  final UsageReport report;
  final DayUsage today;
  final DayUsage? yesterday;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final goalSeconds = report.goalMinutes * 60;
    final left = goalSeconds - today.activeSeconds;
    final previous = yesterday;
    final change = previous != null && previous.hasData
        ? today.activeSeconds - previous.activeSeconds
        : null;
    return AppCard(
      color: palette.surfaceRaised,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Eyebrow('Экранное время сегодня'),
                const SizedBox(height: 12),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatDuration(today.activeSeconds),
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.8,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  change == null
                      ? 'Нет данных за вчера для сравнения'
                      : '${change <= 0 ? '−' : '+'}${formatDuration(change.abs())} к вчерашнему дню',
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                Text(
                  left >= 0
                      ? 'До дневной цели ${formatMinutes(report.goalMinutes)} осталось ${formatDuration(left)}.'
                      : 'Дневная цель ${formatMinutes(report.goalMinutes)} превышена на ${formatDuration(-left)}.',
                  style: TextStyle(color: palette.muted, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GoalRing(
            progress: report.todayGoalProgress,
            center: Center(
              child: Text(
                '${(report.todayGoalProgress * 100).round()}%\nЦЕЛИ',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopApps extends StatelessWidget {
  const _TopApps({required this.report});
  final UsageReport report;

  @override
  Widget build(BuildContext context) {
    final apps = report.appsToday.take(6).toList();
    final total = report.todayUsage.activeSeconds;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('Приложения сегодня'),
          const SizedBox(height: 4),
          if (apps.isEmpty)
            Text(
              'Сегодня ещё не было активных приложений.',
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
          for (var i = 0; i < apps.length; i++)
            AppUsageTile(app: apps[i], rank: i + 1, totalSeconds: total),
          if (report.mode == UsageDataMode.demo)
            Text(
              'Список-пример; значения не считаны с устройства.',
              style: TextStyle(color: context.palette.muted, fontSize: 10),
            ),
        ],
      ),
    );
  }
}

class _Categories extends StatelessWidget {
  const _Categories({required this.minutes, required this.total});
  final Map<UsageCategoryId, int> minutes;
  final int total;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('По категориям сегодня'),
          const SizedBox(height: 6),
          for (final category in usageCategories)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  ValueRow(
                    leading: Icon(
                      category.icon,
                      size: 16,
                      color: categoryColorOf(palette, category.id),
                    ),
                    label: category.name,
                    secondary: formatPercent(
                      total == 0 ? 0 : (minutes[category.id] ?? 0) / total,
                    ),
                    value: formatMinutes(minutes[category.id] ?? 0),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: LinearProgressIndicator(
                      value: total == 0
                          ? 0
                          : (minutes[category.id] ?? 0) / total,
                      minHeight: 5,
                      backgroundColor: palette.border,
                      color: categoryColorOf(palette, category.id),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Категории есть только в демо-примере: REBOOT не классифицирует реальные приложения.',
            style: TextStyle(color: palette.muted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
