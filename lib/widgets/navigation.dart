import 'package:flutter/material.dart';

import '../theme/reboot_themes.dart';

/// Order matters: indices are used by the app shell ([AppSection]).
const _destinations = [
  (Icons.space_dashboard_rounded, 'Обзор'),
  (Icons.query_stats_rounded, 'Аналитика'),
  (Icons.view_timeline_outlined, 'Лента'),
  (Icons.timer_outlined, 'Фокус'),
  (Icons.flag_outlined, 'Цели'),
  (Icons.insights_outlined, 'Отчёт'),
  (Icons.shield_outlined, 'Приватность'),
  (Icons.person_outline_rounded, 'Профиль'),
];

abstract final class AppSection {
  static const dashboard = 0,
      analytics = 1,
      timeline = 2,
      focus = 3,
      goals = 4,
      report = 5,
      privacy = 6,
      settings = 7;
}

/// Sections in the compact bottom bar; the rest live under «Ещё».
const _compactPrimary = [
  AppSection.dashboard,
  AppSection.analytics,
  AppSection.timeline,
  AppSection.focus,
];

class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.index,
    required this.displayName,
    required this.onSelect,
    this.statusTitle = 'Демо-режим',
    this.statusBody = 'Показываются демонстрационные примеры',
    this.collecting = false,
  });

  final int index;
  final String displayName;
  final ValueChanged<int> onSelect;
  final String statusTitle;
  final String statusBody;
  final bool collecting;

  @override
  Widget build(BuildContext context) => Container(
    width: 236,
    decoration: BoxDecoration(
      color: context.palette.background,
      border: Border(right: BorderSide(color: context.palette.border)),
    ),
    padding: const EdgeInsets.fromLTRB(20, 28, 16, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: context.palette.accent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.bolt_rounded,
                color: context.palette.onAccent,
                size: 23,
              ),
            ),
            const SizedBox(width: 11),
            const Text(
              'REBOOT',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 17,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 36),
        Padding(
          padding: const EdgeInsets.only(left: 12, bottom: 12),
          child: Text(
            'МЕНЮ',
            style: TextStyle(
              color: context.palette.muted,
              fontSize: 10,
              letterSpacing: 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              // Profile and settings open from the profile row below.
              for (var i = 0; i < _destinations.length; i++)
                if (i != AppSection.settings)
                  _SidebarItem(
                    index: i,
                    selected: index == i,
                    onTap: () => onSelect(i),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: context.palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                collecting ? Icons.sensors_rounded : Icons.shield_outlined,
                size: 18,
                color: collecting
                    ? context.palette.success
                    : context.palette.accentSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                statusTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                statusBody,
                style: TextStyle(color: context.palette.muted, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 17),
        Semantics(
          button: true,
          selected: index == AppSection.settings,
          label: 'Профиль и настройки',
          child: Material(
            color: index == AppSection.settings
                ? context.palette.accent.withValues(alpha: .13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelect(AppSection.settings),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: context.palette.surfaceRaised,
                      child: Icon(
                        Icons.person_outline,
                        size: 18,
                        color: context.palette.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Профиль и настройки',
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.settings_outlined,
                      size: 16,
                      color: context.palette.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final destination = _destinations[index];

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected
            ? context.palette.accent.withValues(alpha: .13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(
                  destination.$1,
                  size: 18,
                  color: selected
                      ? context.palette.accent
                      : context.palette.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    destination.$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? context.palette.accent
                          : context.palette.text,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    super.key,
    required this.index,
    required this.onSelect,
  });

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: context.palette.background,
      border: Border(top: BorderSide(color: context.palette.border)),
    ),
    padding: const EdgeInsets.only(top: 7, bottom: 4),
    child: NavigationBar(
      height: 62,
      backgroundColor: context.palette.background,
      indicatorColor: context.palette.accent.withValues(alpha: .13),
      selectedIndex: _compactPrimary.contains(index)
          ? _compactPrimary.indexOf(index)
          : _compactPrimary.length,
      onDestinationSelected: (i) => i < _compactPrimary.length
          ? onSelect(_compactPrimary[i])
          : _showMore(context),
      destinations: [
        for (final section in _compactPrimary)
          NavigationDestination(
            icon: Icon(_destinations[section].$1),
            label: _destinations[section].$2,
          ),
        const NavigationDestination(
          icon: Icon(Icons.more_horiz_rounded),
          label: 'Ещё',
        ),
      ],
    ),
  );

  Future<void> _showMore(BuildContext context) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _destinations.length; i++)
              if (!_compactPrimary.contains(i))
                ListTile(
                  leading: Icon(_destinations[i].$1),
                  title: Text(_destinations[i].$2),
                  selected: index == i,
                  onTap: () => Navigator.pop(sheetContext, i),
                ),
          ],
        ),
      ),
    );
    if (picked != null) onSelect(picked);
  }
}
