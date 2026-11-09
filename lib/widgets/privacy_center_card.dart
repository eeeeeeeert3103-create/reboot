import 'package:flutter/material.dart';

import '../services/data_exporter.dart';
import '../services/privacy_data_store.dart';
import '../services/user_settings_store.dart';
import '../theme/reboot_themes.dart';
import 'app_card.dart';

/// "Your data": where it is stored, export and deletion.
class PrivacyCenterCard extends StatelessWidget {
  const PrivacyCenterCard({
    super.key,
    required this.settings,
    required this.dataStore,
    required this.onDelete,
    this.exporter,
    this.usageData,
    this.onClearHistory,
  });

  final UserSettings settings;
  final PrivacyDataStore dataStore;
  final Future<LocalDataDeletionResult> Function() onDelete;
  final DataExporter? exporter;

  /// Usage history, streak and privacy choices to include in the export.
  final Map<String, Object?> Function()? usageData;

  /// Deletes only the collected usage history.
  final Future<void> Function()? onClearHistory;

  bool get _canExport => exporter?.canExport ?? dataStore.canExport;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final folder = dataStore.appDataDirectoryPath;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Heading(icon: Icons.folder_outlined, title: 'Ваши данные'),
          const SizedBox(height: 10),
          Text(
            'Все данные REBOOT хранятся только на этом устройстве и никуда не отправляются.',
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
          ),
          if (folder != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              folder,
              style: TextStyle(color: palette.textSecondary, fontSize: 11),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: _canExport ? () => _exportFile(context) : null,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Экспортировать данные'),
              ),
              if (onClearHistory != null)
                TextButton.icon(
                  onPressed: () => _confirmHistoryDeletion(context),
                  icon: const Icon(Icons.history_toggle_off_rounded),
                  label: const Text('Удалить историю использования'),
                ),
              TextButton.icon(
                onPressed: () => _confirmDeletion(context),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Удалить все локальные данные'),
                style: TextButton.styleFrom(foregroundColor: palette.danger),
              ),
            ],
          ),
          if (!_canExport) ...[
            const SizedBox(height: 4),
            Text(
              exporter?.unavailableReason ?? dataStore.exportUnavailableReason,
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _exportFile(BuildContext context) async {
    final content = dataStore.readableExport(
      settings,
      usageData: usageData?.call() ?? const {},
    );
    try {
      final String? path;
      if (exporter != null) {
        path = await exporter!.save(dataStore.suggestedExportName(), content);
      } else {
        path = (await dataStore.writeExportFile(
          dataStore.suggestedExportName(),
          content,
        )).path;
      }
      if (path == null || !context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Файл экспорта создан'),
          content: SingleChildScrollView(
            child: SelectableText(
              'Файл сохранён. Откройте его по этому пути:\n\n$path',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Готово'),
            ),
          ],
        ),
      );
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать файл экспорта.')),
      );
    }
  }

  Future<void> _confirmHistoryDeletion(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить историю использования?'),
        content: const Text(
          'Будут удалены собранные сессии, запуски, периоды бездействия и блокировки. Сбор остановится; согласие, настройки и серия дней останутся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Удалить историю'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await onClearHistory!();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('История использования удалена.')),
      );
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить историю.')),
      );
    }
  }

  Future<void> _confirmDeletion(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить все локальные данные?'),
        content: const Text(
          'Сбор остановится. Имя, цель, тема и предпочтения будут сброшены. Согласие, история использования, серия дней и отзывы будут удалены. Уже сохранённые файлы экспорта не удаляются.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await onDelete();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          LocalDataDeletionResult.complete => 'Все локальные данные удалены.',
          LocalDataDeletionResult.settingsDeletionFailed => 'Не удалось подтвердить удаление настроек. Остальные данные оставлены.',
          LocalDataDeletionResult.feedbackDeletionFailedAfterSettings =>
            'Настройки удалены, но не удалось удалить локальные отзывы.',
          LocalDataDeletionResult.streakDeletionFailedAfterFeedback =>
            'Настройки и отзывы удалены, но не удалось удалить историю серии.',
          LocalDataDeletionResult.usageDataDeletionFailed =>
            'Не удалось удалить историю использования или согласие.',
        }),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 17, color: context.palette.accent),
      const SizedBox(width: 9),
      Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ],
  );
}
