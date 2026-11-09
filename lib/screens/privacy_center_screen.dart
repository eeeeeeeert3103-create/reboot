import 'package:flutter/material.dart';

import '../content/privacy_policy.dart';
import '../models/collector_models.dart';
import '../services/data_exporter.dart';
import '../services/privacy_data_store.dart';
import '../services/usage_controller.dart';
import '../services/user_settings_store.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/privacy_center_card.dart';
import '../widgets/ui_kit.dart';
import 'privacy_policy_screen.dart';

class PrivacyCenterScreen extends StatelessWidget {
  const PrivacyCenterScreen({
    super.key,
    required this.controller,
    required this.settings,
    required this.privacyDataStore,
    required this.onDeleteLocalData,
    this.exporter,
    this.backgroundControls,
    this.extraExportData,
  });

  final UsageController controller;
  final UserSettings settings;
  final PrivacyDataStore privacyDataStore;
  final Future<LocalDataDeletionResult> Function() onDeleteLocalData;
  final DataExporter? exporter;
  final Widget? backgroundControls;

  /// Focus sessions, goals and similar data added to the export.
  final Map<String, Object?> Function()? extraExportData;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return PageFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Центр приватности',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 7),
            Text(
              'Что собирает REBOOT, где это хранится и как этим управлять.',
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
            const SizedBox(height: Gap.m),
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Principle(Icons.computer_rounded, 'Local-first'),
                _Principle(Icons.architecture_rounded, 'Privacy by design'),
                _Principle(Icons.compress_rounded, 'Минимум данных'),
                _Principle(Icons.visibility_outlined, 'Прозрачность'),
                _Principle(Icons.block_rounded, 'Без скрытого сбора'),
                _Principle(Icons.campaign_outlined, 'Без рекламного трекинга'),
              ],
            ),
            const SizedBox(height: Gap.l),
            _CollectionCard(controller: controller),
            if (backgroundControls != null) ...[
              const SizedBox(height: Gap.m),
              backgroundControls!,
            ],
            const SizedBox(height: Gap.m),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeading('Что собирается и зачем'),
                  const SizedBox(height: 6),
                  for (final item in collectedDataSummary)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.purpose,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${item.storage} · ${item.retention}',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(height: 20),
                  Text(
                    'Не собирается: заголовки окон, адреса сайтов, содержимое документов и переписки, нажатия клавиш, пароли, снимки экрана, местоположение. Сетевой отправки, аналитики и рекламы в приложении нет.',
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.m),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) => PrivacyCenterCard(
                settings: settings,
                dataStore: privacyDataStore,
                onDelete: onDeleteLocalData,
                exporter: exporter,
                usageData: () => {
                  ...controller.exportData(),
                  ...?extraExportData?.call(),
                },
                onClearHistory: controller.clearUsageHistory,
              ),
            ),
            const SizedBox(height: Gap.m),
            AppCard(
              child: Row(
                children: [
                  Icon(Icons.description_outlined, color: palette.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Политика конфиденциальности',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Версия $privacyPolicyVersion · черновик, требует юридической проверки',
                          style: TextStyle(color: palette.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => PrivacyPolicyScreen.open(context),
                    child: const Text('Открыть'),
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

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.controller});
  final UsageController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final palette = context.palette;
      final choices = controller.choices;
      final status = controller.status;
      final available = controller.collectorAvailable;
      final collecting = controller.isCollecting;
      final mode = controller.mode;
      final statusColor = collecting
          ? palette.success
          : (available ? palette.warning : palette.muted);
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sensors_rounded, size: 17, color: palette.accent),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'Сбор статистики',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                ModeBadge(mode: mode, compact: true),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusText(status, collecting),
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ValueRow(
              label: 'Системные разрешения',
              value: status == null
                  ? 'проверяется…'
                  : (status.permissionGranted ? 'не требуются' : 'недоступно'),
            ),
            ValueRow(
              label: 'Согласие',
              value: choices.collectionConsent
                  ? 'дано ${_date(choices.consentChangedAt)}'
                  : 'не дано',
            ),
            if (controller.lastSync != null)
              ValueRow(
                label: 'Последнее сохранение',
                value: _time(controller.lastSync!),
              ),
            const Divider(height: 22),
            Material(
              color: Colors.transparent,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Согласие на сбор статистики',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  'Разрешает REBOOT учитывать активное приложение, запуски, бездействие и блокировку экрана на этом устройстве.',
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
                value: choices.collectionConsent,
                onChanged: (value) =>
                    value ? _grantConsent(context) : _revokeConsent(context),
              ),
            ),
            const SizedBox(height: 8),
            const Eyebrow('Источник данных'),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('DEMO')),
                ButtonSegment(value: true, label: Text('REAL')),
              ],
              selected: {choices.preferRealData && choices.collectionConsent},
              onSelectionChanged: (value) {
                final real = value.single;
                if (real && !choices.collectionConsent) {
                  _grantConsent(context, alsoReal: true);
                } else {
                  controller.setPreferRealData(real);
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              available
                  ? 'REAL — данные этого устройства, DEMO — заранее подготовленные примеры. Выбор REAL включает сбор, DEMO — останавливает его.'
                  : 'Сборщик недоступен в этой сборке или на этой платформе, поэтому показываются только демо-примеры.',
              style: TextStyle(
                color: palette.muted,
                fontSize: 11,
                height: 1.45,
              ),
            ),
            if (controller.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.lastError!,
                style: TextStyle(color: palette.danger, fontSize: 11),
              ),
            ],
            for (final issue in [
              controller.consentIssue,
              controller.historyIssue,
              controller.streakIssue,
            ])
              if (issue != null) ...[
                const SizedBox(height: 6),
                Text(
                  issue,
                  style: TextStyle(color: palette.warning, fontSize: 11),
                ),
              ],
            const SizedBox(height: 10),
            Text(
              'Ограничения: учитывается только активное (переднее) приложение и только пока REBOOT запущен. Видео или чтение без ввода дольше 2 минут считается бездействием. Сон системы учитывается как блокировка.',
              style: TextStyle(
                color: palette.muted,
                fontSize: 11,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: controller.refreshStatus,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Проверить статус'),
            ),
          ],
        ),
      );
    },
  );

  String _statusText(CollectorStatus? status, bool collecting) {
    if (status == null) return 'Проверяем сборщик…';
    final base = switch (status.lifecycle) {
      CollectorLifecycle.unavailable => 'Сборщик недоступен.',
      CollectorLifecycle.permissionRequired => 'Нужно системное разрешение.',
      CollectorLifecycle.ready => 'Сборщик готов, сбор не запущен.',
      CollectorLifecycle.collecting => 'Сбор идёт.',
      CollectorLifecycle.stopped => 'Сбор остановлен.',
      CollectorLifecycle.failed => 'Ошибка сборщика.',
    };
    return '$base ${status.message}';
  }

  static String _date(DateTime? value) {
    if (value == null) return '';
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
  }

  static String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }

  Future<void> _grantConsent(
    BuildContext context, {
    bool alsoReal = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Разрешить сбор статистики?'),
        content: const SingleChildScrollView(
          child: Text(
            'REBOOT будет учитывать на этом устройстве:\n'
            '• какое приложение активно и сколько времени;\n'
            '• запуски приложений;\n'
            '• периоды без ввода (только время, не сами нажатия);\n'
            '• блокировку, разблокировку и сон.\n\n'
            'Заголовки окон, сайты, содержимое и нажатия клавиш не собираются. '
            'Данные хранятся только локально, срок хранения истории — 90 дней. '
            'Согласие можно отозвать в любой момент.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Разрешить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.setConsent(true);
    if (alsoReal) await controller.setPreferRealData(true);
  }

  Future<void> _revokeConsent(BuildContext context) async {
    await controller.setConsent(false);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Сбор остановлен. Уже собранная история хранится до 90 дней; удалить её можно ниже.',
        ),
      ),
    );
  }
}

class _Principle extends StatelessWidget {
  const _Principle(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: palette.accent),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
