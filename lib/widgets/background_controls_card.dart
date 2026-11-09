import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/streak.dart';
import '../services/app_shell.dart';
import '../services/usage_controller.dart';
import '../theme/reboot_themes.dart';
import 'app_card.dart';
import 'ui_kit.dart';

/// Background collection, launch at login, stop and quit.
class BackgroundControlsCard extends StatelessWidget {
  const BackgroundControlsCard({
    super.key,
    required this.controller,
    required this.shell,
    required this.onQuit,
  });

  final UsageController controller;
  final AppShellBridge shell;
  final Future<void> Function() onQuit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, shell]),
    builder: (context, _) {
      final palette = context.palette;
      final state = shell.state;
      final choices = controller.choices;
      final real = controller.mode == UsageDataMode.real;
      final (statusColor, status) = !choices.wantsCollection
          ? (palette.muted, 'Сбор выключен: режим DEMO или нет согласия')
          : controller.isPaused
          ? (
              palette.warning,
              'Сбор приостановлен вручную до возобновления или перезапуска',
            )
          : controller.isCollecting
          ? (
              palette.success,
              state.backgroundMode
                  ? 'Сбор идёт и продолжится при закрытом окне'
                  : 'Сбор идёт, пока открыто окно REBOOT',
            )
          : (palette.warning, controller.status?.message ?? 'Сбор не идёт');
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
                    'Фоновый сбор',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                ModeBadge(mode: controller.mode, compact: true),
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
                  child: Text(status, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const Divider(height: 22),
            Material(
              color: Colors.transparent,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Продолжать сбор при закрытом окне',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  !state.available
                      ? 'Недоступно в этой сборке: нет нативной оболочки.'
                      : _alwaysInTray
                      ? 'На Windows REBOOT всегда работает в системном трее: закрытие окна сворачивает его в трей. Полностью остановить — «Завершить REBOOT».'
                      : 'REBOOT останется в ${_trayName()} со значком; «Завершить REBOOT» останавливает всё.',
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
                value:
                    (choices.backgroundCollection || _alwaysInTray) &&
                    state.available,
                onChanged: state.available && !_alwaysInTray
                    ? (value) async {
                        await controller.setBackgroundCollection(value);
                        await shell.setBackgroundMode(value);
                      }
                    : null,
              ),
            ),
            Material(
              color: Colors.transparent,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Запускать при входе в систему',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  !state.available
                      ? 'Недоступно в этой сборке.'
                      : state.launchAtLoginMessage.isNotEmpty
                      ? state.launchAtLoginMessage
                      : 'Выключено по умолчанию. Можно выключить в любой момент.',
                  style: TextStyle(
                    color:
                        state.launchAtLoginStatus == 'requiresApproval' ||
                            state.launchAtLoginStatus == 'error'
                        ? palette.warning
                        : palette.muted,
                    fontSize: 11,
                  ),
                ),
                value: state.launchAtLogin,
                onChanged: state.launchAtLoginSupported
                    ? (value) => shell.setLaunchAtLogin(value)
                    : null,
              ),
            ),
            if (shell.lastError != null)
              Text(
                shell.lastError!,
                style: TextStyle(color: palette.danger, fontSize: 11),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      !choices.wantsCollection || !real && !controller.isPaused
                      ? null
                      : controller.isPaused || !controller.isCollecting
                      ? controller.resumeCollection
                      : controller.pauseCollection,
                  icon: Icon(
                    controller.isCollecting
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: Text(
                    controller.isCollecting
                        ? 'Остановить сбор'
                        : 'Возобновить сбор',
                  ),
                ),
                TextButton.icon(
                  onPressed: onQuit,
                  icon: const Icon(Icons.power_settings_new_rounded, size: 18),
                  label: const Text('Завершить REBOOT'),
                  style: TextButton.styleFrom(foregroundColor: palette.danger),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Без запущенного REBOOT и при выключенном компьютере сбор не ведётся, и это время не считается экранным.',
              style: TextStyle(color: palette.muted, fontSize: 10, height: 1.4),
            ),
          ],
        ),
      );
    },
  );

  static bool get _alwaysInTray =>
      defaultTargetPlatform == TargetPlatform.windows;

  String _trayName() => defaultTargetPlatform == TargetPlatform.windows
      ? 'системном трее'
      : 'строке меню';
}
