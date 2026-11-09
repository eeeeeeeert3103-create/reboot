import 'package:flutter/material.dart';

import '../models/usage_data.dart';
import '../theme/reboot_themes.dart';
import 'app_card.dart';

/// Explicit UI copy for source states. The shipped app currently uses Demo.
class UsageSourceNotice extends StatelessWidget {
  const UsageSourceNotice({super.key, required this.state});
  final UsageSourceState state;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (state) {
      UsageSourceState.demo => (
        Icons.science_outlined,
        'Демо-пример',
        'Значения ниже подготовлены для демонстрации и не считаны с устройства.',
      ),
      UsageSourceState.loading => (
        Icons.hourglass_top_rounded,
        'Загружаем сводку',
        'Пока нет готовых данных для выбранного периода.',
      ),
      UsageSourceState.empty => (
        Icons.inbox_outlined,
        'Нет данных за период',
        'В этом периоде нет записей. Это не означает нулевое использование.',
      ),
      UsageSourceState.permissionDenied => (
        Icons.lock_outline_rounded,
        'Доступ не предоставлен',
        'Статистика устройства недоступна. Можно продолжить знакомство с демонстрационным примером.',
      ),
    };
    return Semantics(
      liveRegion: state == UsageSourceState.loading,
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: context.palette.accent, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 11,
                      height: 1.4,
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
