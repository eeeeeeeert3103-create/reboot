import 'package:flutter/material.dart';

import '../services/user_settings_store.dart';
import '../services/privacy_data_store.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/feedback_center_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.privacyDataStore,
    this.onOpenPrivacy,
    this.backgroundControls,
    this.aiAssistant,
  });
  final UserSettings settings;
  final ValueChanged<UserSettings> onChanged;
  final PrivacyDataStore privacyDataStore;
  final VoidCallback? onOpenPrivacy;
  final Widget? backgroundControls;
  final Widget? aiAssistant;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double _goalHours;
  late UserSettings _currentSettings;
  @override
  void initState() {
    super.initState();
    _goalHours = widget.settings.goalHours;
    _currentSettings = widget.settings;
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.goalHours != widget.settings.goalHours) {
      _goalHours = widget.settings.goalHours;
    }
    if (oldWidget.settings != widget.settings) {
      _currentSettings = widget.settings;
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Профиль и настройки',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 7),
          Text(
            'Профиль и предпочтения сохраняются только на этом устройстве.',
            style: TextStyle(color: context.palette.muted, fontSize: 14),
          ),
          const SizedBox(height: 20),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _GroupTitle(
                  icon: Icons.person_outline_rounded,
                  title: 'Профиль',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 23,
                      backgroundColor: context.palette.surfaceRaised,
                      child: Icon(
                        Icons.person_rounded,
                        color: context.palette.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentSettings.profileName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Имя хранится в настройках приложения',
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _editProfile,
                      child: const Text('Изменить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _GroupTitle(
                  icon: Icons.flag_outlined,
                  title: 'Цель экранного времени',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      '${_goalHours.toStringAsFixed(1).replaceAll('.', ',')} ч',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'в день',
                      style: TextStyle(color: context.palette.muted),
                    ),
                  ],
                ),
                Slider(
                  value: _goalHours,
                  min: 2,
                  max: 10,
                  divisions: 16,
                  label: '${_goalHours.toStringAsFixed(1)} ч',
                  onChanged: (value) => setState(() => _goalHours = value),
                  onChangeEnd: (value) =>
                      _applySettings(_copy(goalHours: value)),
                ),
                Text(
                  'Цель обновляется в Обзоре, Аналитике, примерах рекомендаций и в серии дней.',
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _ThemePickerCard(
            selected: _currentSettings.themeId,
            onSelected: (id) =>
                _applySettings(_currentSettings.copyWith(themeId: id)),
          ),
          if (widget.aiAssistant != null) ...[
            const SizedBox(height: 12),
            widget.aiAssistant!,
          ],
          if (widget.backgroundControls != null) ...[
            const SizedBox(height: 12),
            widget.backgroundControls!,
          ],
          const SizedBox(height: 12),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _GroupTitle(
                  icon: Icons.notifications_off_outlined,
                  title: 'Уведомления',
                ),
                const SizedBox(height: 8),
                Text(
                  'REBOOT не отправляет уведомлений и напоминаний. Серия дней и цель видны только внутри приложения.',
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Row(
              children: [
                Icon(Icons.shield_outlined, color: context.palette.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Согласие на сбор, режим REAL/DEMO, экспорт и удаление данных находятся в Центре приватности.',
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
                if (widget.onOpenPrivacy != null)
                  TextButton(
                    onPressed: widget.onOpenPrivacy,
                    child: const Text('Открыть'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FeedbackCenterCard(dataStore: widget.privacyDataStore),
          const SizedBox(height: 10),
          Center(
            child: Text(
              'REBOOT 1.0.0 · данные хранятся только на этом устройстве',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.muted, fontSize: 10),
            ),
          ),
        ],
      ),
    ),
  );

  UserSettings _copy({
    String? profileName,
    bool? notifications,
    bool? weeklySummary,
    double? goalHours,
  }) => _currentSettings.copyWith(
    profileName: profileName,
    notifications: notifications,
    weeklySummary: weeklySummary,
    goalHours: goalHours,
  );

  void _applySettings(UserSettings settings) {
    setState(() => _currentSettings = settings);
    widget.onChanged(settings);
  }

  Future<void> _editProfile() async {
    final controller = TextEditingController(
      text: _currentSettings.profileName,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Профиль'),
        content: TextField(
          controller: controller,
          maxLength: 80,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Имя'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      _applySettings(_copy(profileName: name));
    }
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.icon, required this.title});
  final IconData icon;
  final String title;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 17, color: context.palette.accent),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

class _ThemePickerCard extends StatelessWidget {
  const _ThemePickerCard({required this.selected, required this.onSelected});
  final AppThemeId selected;
  final ValueChanged<AppThemeId> onSelected;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _GroupTitle(
          icon: Icons.palette_outlined,
          title: 'Тема оформления',
        ),
        const SizedBox(height: 5),
        Text(
          'Применяется сразу и сохраняется на этом устройстве.',
          style: TextStyle(color: context.palette.muted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final theme in RebootThemes.all)
              _ThemeOption(
                theme: theme,
                selected: theme.id == selected,
                onTap: () => onSelected(theme.id),
              ),
          ],
        ),
      ],
    ),
  );
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.theme,
    required this.selected,
    required this.onTap,
  });
  final RebootThemeDefinition theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final preview = theme.palette;
    return Semantics(
      selected: selected,
      button: true,
      label: 'Тема ${theme.name}',
      child: Material(
        color: selected
            ? palette.accent.withValues(alpha: .13)
            : palette.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? palette.accent : palette.border,
              ),
            ),
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final color in [
                    preview.background,
                    preview.surfaceRaised,
                    preview.accent,
                  ])
                    Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.only(right: 3),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: palette.border),
                      ),
                    ),
                  const SizedBox(width: 6),
                  Text(
                    theme.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? palette.accent : palette.text,
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.check_rounded, size: 15, color: palette.accent),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
