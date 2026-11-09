import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../content/privacy_policy.dart';
import '../services/app_shell.dart';
import '../services/usage_controller.dart';
import '../services/user_settings_store.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/ui_kit.dart';
import 'privacy_policy_screen.dart';

/// First-run flow. Every step can be skipped; skipping means DEMO without
/// consent, so nothing is collected unless the user explicitly agrees.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.controller,
    this.shell,
    required this.settings,
    required this.onSettingsChanged,
  });

  final UsageController controller;
  final AppShellBridge? shell;
  final UserSettings settings;
  final ValueChanged<UserSettings> onSettingsChanged;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _stepCount = 7;
  int _step = 0;
  late double _goalHours = widget.settings.goalHours;
  bool _consent = false;
  bool _real = false;
  bool _background = true;
  // Windows keeps REBOOT in the tray, so start with login is offered on.
  bool _autostart = defaultTargetPlatform == TargetPlatform.windows;
  bool _finishing = false;

  void _next() {
    if (_step < _stepCount - 1) {
      setState(() => _step++);
    } else {
      _finish();
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  Future<void> _finish({bool skipped = false}) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    widget.onSettingsChanged(widget.settings.copyWith(goalHours: _goalHours));
    await widget.controller.completeOnboarding(
      consent: !skipped && _consent,
      preferReal: !skipped && _consent && _real,
    );
    final shell = widget.shell;
    await widget.controller.setBackgroundCollection(_background);
    if (shell != null && shell.state.available) {
      await shell.setBackgroundMode(_background);
      if (!skipped && _autostart && shell.state.launchAtLoginSupported) {
        await shell.setLaunchAtLogin(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: palette.accent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.bolt_rounded,
                          color: palette.onAccent,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'REBOOT',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _finishing
                            ? null
                            : () => _finish(skipped: true),
                        child: const Text('Пропустить'),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.m),
                  Semantics(
                    label: 'Шаг ${_step + 1} из $_stepCount',
                    child: ExcludeSemantics(
                      child: Row(
                        children: [
                          for (var i = 0; i < _stepCount; i++) ...[
                            if (i > 0) const SizedBox(width: 6),
                            Expanded(
                              child: Container(
                                height: 3,
                                decoration: BoxDecoration(
                                  color: i <= _step
                                      ? palette.accent
                                      : palette.border,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.l),
                  Expanded(
                    child: SingleChildScrollView(child: _buildStep(context)),
                  ),
                  const SizedBox(height: Gap.m),
                  Row(
                    children: [
                      if (_step > 0)
                        TextButton(
                          onPressed: _back,
                          child: const Text('Назад'),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: _finishing ? null : _next,
                            child: Text(
                              _step == _stepCount - 1
                                  ? 'Перейти к обзору'
                                  : 'Далее',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    final palette = context.palette;
    final muted = TextStyle(color: palette.muted, fontSize: 13, height: 1.55);
    final title = Theme.of(context).textTheme.headlineMedium;
    switch (_step) {
      case 0:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Добро пожаловать в REBOOT', style: title),
            const SizedBox(height: 12),
            Text(
              'REBOOT помогает увидеть, сколько времени вы проводите за компьютером и в каких приложениях, '
              'и самостоятельно выбрать комфортный ориентир. Ограничения для приложений '
              'включаются только вами. REBOOT не ставит диагнозов и не оценивает здоровье.',
              style: muted,
            ),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Какие данные и где они хранятся', style: title),
            const SizedBox(height: 12),
            Text(
              'Только с вашего согласия REBOOT учитывает активное приложение и время его использования, '
              'запуски приложений, периоды без ввода, блокировку и сон. Заголовки окон, сайты, '
              'содержимое и нажатия клавиш не собираются.',
              style: muted,
            ),
            const SizedBox(height: 10),
            Text(
              'Всё хранится только на этом устройстве. Сетевой отправки, аналитики и рекламы нет. '
              'Историю можно экспортировать или удалить в Центре приватности.',
              style: muted,
            ),
            const SizedBox(height: 6),
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => PrivacyPolicyScreen.open(context),
              child: Text(
                'Политика конфиденциальности ($privacyPolicyVersion)',
              ),
            ),
          ],
        );
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Тема оформления', style: title),
            const SizedBox(height: 12),
            Text('Её можно поменять позже в настройках.', style: muted),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final theme in RebootThemes.all)
                  ChoiceChip(
                    label: Text(theme.name),
                    avatar: CircleAvatar(
                      backgroundColor: theme.palette.accent,
                      radius: 6,
                    ),
                    selected: widget.settings.themeId == theme.id,
                    onSelected: (_) => widget.onSettingsChanged(
                      widget.settings.copyWith(themeId: theme.id),
                    ),
                  ),
              ],
            ),
          ],
        );
      case 3:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Дневная цель', style: title),
            const SizedBox(height: 12),
            Text(
              'Ориентир экранного времени в день. Это ваш личный выбор, а не рекомендация. '
              'По нему считаются серия дней и прогресс.',
              style: muted,
            ),
            const SizedBox(height: 18),
            AppCard(
              child: Column(
                children: [
                  Text(
                    '${_goalHours.toStringAsFixed(1).replaceAll('.', ',')} ч в день',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Slider(
                    value: _goalHours,
                    min: 2,
                    max: 10,
                    divisions: 16,
                    label: '${_goalHours.toStringAsFixed(1)} ч',
                    onChanged: (value) => setState(() => _goalHours = value),
                  ),
                ],
              ),
            ),
          ],
        );
      case 4:
        final available = widget.controller.collectorAvailable;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Источник данных и согласие', style: title),
            const SizedBox(height: 12),
            RadioGroup<bool>(
              groupValue: _real && _consent,
              onChanged: (value) => setState(() {
                _real = value ?? false;
                if (!_real) _consent = false;
              }),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: const Text('DEMO — демонстрационные примеры'),
                    subtitle: Text(
                      'Ничего не собирается. Все экраны помечены «ДЕМО».',
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    enabled: available,
                    title: const Text('REAL — данные этого устройства'),
                    subtitle: Text(
                      available ? 'Требует согласия ниже.' : 'Недоступно: сборщик не встроен в эту сборку или платформу.',
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _consent,
              onChanged: available
                  ? (value) => setState(() {
                      _consent = value ?? false;
                      if (_consent) _real = true;
                    })
                  : null,
              title: const Text(
                'Я согласен(на) на сбор статистики использования на этом устройстве',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                'Можно отозвать в Центре приватности в любой момент.',
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ),
          ],
        );
      case 5:
        final shellAvailable = widget.shell?.state.available ?? false;
        final autostartSupported =
            widget.shell?.state.launchAtLoginSupported ?? false;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Фон и автозапуск', style: title),
            const SizedBox(height: 12),
            Text(
              'Чтобы статистика не обрывалась при закрытии окна, REBOOT может оставаться '
              'в строке меню (macOS) или системном трее (Windows). Значок всегда виден, '
              'а «Завершить REBOOT» полностью останавливает приложение.',
              style: muted,
            ),
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Продолжать сбор при закрытом окне'),
              subtitle: Text(
                shellAvailable
                    ? 'Можно изменить в Настройках.'
                    : 'Недоступно в этой сборке.',
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
              value: _background && shellAvailable,
              onChanged: shellAvailable
                  ? (v) => setState(() => _background = v)
                  : null,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Запускать при входе в систему'),
              subtitle: Text(
                autostartSupported
                    ? (defaultTargetPlatform == TargetPlatform.windows
                          ? 'Рекомендуется на Windows, чтобы сбор не прерывался. Можно снять.'
                          : 'Необязательно. Выключено по умолчанию.')
                    : 'Недоступно на этой системе или в этой сборке.',
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
              value: _autostart && autostartSupported,
              onChanged: autostartSupported
                  ? (v) => setState(() => _autostart = v)
                  : null,
            ),
          ],
        );
      default:
        final status = widget.controller.status;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Разрешения системы', style: title),
            const SizedBox(height: 12),
            Text(
              'Для этих данных REBOOT не нужны дополнительные системные разрешения на macOS и Windows: '
              'используются только сведения об активном приложении и времени последнего ввода.',
              style: muted,
            ),
            const SizedBox(height: 14),
            AppCard(
              child: Column(
                children: [
                  ValueRow(
                    label: 'Сборщик',
                    value: widget.controller.collectorAvailable
                        ? 'доступен'
                        : 'недоступен',
                  ),
                  ValueRow(
                    label: 'Системные разрешения',
                    value: status?.permissionGranted ?? false
                        ? 'не требуются'
                        : '—',
                  ),
                  ValueRow(
                    label: 'Выбранный режим',
                    value: _consent && _real ? 'REAL' : 'DEMO',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Сбор идёт только пока REBOOT запущен. Видео без ввода дольше 2 минут считается бездействием.',
              style: TextStyle(color: palette.muted, fontSize: 11, height: 1.5),
            ),
          ],
        );
    }
  }
}
