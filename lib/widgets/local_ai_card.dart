import 'package:flutter/material.dart';

import '../models/streak.dart';
import '../models/usage_report.dart';
import '../services/local_ai.dart';
import '../services/usage_controller.dart';
import '../theme/reboot_themes.dart';
import 'app_card.dart';
import 'ui_kit.dart';

/// Opt-in advice from a model running on this computer (Ollama), with a
/// rule-based fallback that never leaves the app.
class LocalAiCard extends StatefulWidget {
  const LocalAiCard({
    super.key,
    required this.controller,
    required this.today,
    this.assistant,
  });

  final UsageController controller;
  final LocalDay today;
  final LocalAiAssistant? assistant;

  @override
  State<LocalAiCard> createState() => _LocalAiCardState();
}

class _LocalAiCardState extends State<LocalAiCard> {
  late final LocalAiAssistant _ai = widget.assistant ?? LocalAiAssistant();
  List<String>? _models;
  String? _status;
  bool _busy = false;

  /// The last answer lives only in memory until the app closes.
  String? _advice;
  List<String>? _ruleTips;

  UsageController get _c => widget.controller;

  ({UsageReport week, ActivityHeatmap? heatmap}) _data() {
    if (_c.mode == UsageDataMode.real) {
      final from = widget.today.addDays(-6);
      return (
        week: buildRangeReport(
          index: _c.index,
          from: from,
          to: widget.today,
          goalMinutes: _c.report(today: widget.today).goalMinutes,
        ),
        heatmap: _c.index.heatmap(from, widget.today),
      );
    }
    return (week: _c.report(today: widget.today), heatmap: null);
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final models = await _ai.models();
      setState(() {
        _models = models;
        _status = models.isEmpty
            ? 'Ollama запущена, но моделей нет. Выполните в терминале: ollama pull llama3.2'
            : 'Ollama найдена: моделей ${models.length}.';
      });
      if (models.isNotEmpty && !models.contains(_c.choices.localAiModel)) {
        await _c.setLocalAi(enabled: true, model: models.first);
      }
    } on LocalAiException catch (error) {
      setState(() {
        _models = null;
        _status =
            '${error.message} Установите Ollama с ollama.com, запустите её и загрузите модель.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enable() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Включить локального ИИ-помощника?'),
        content: const SingleChildScrollView(
          child: Text(
            'REBOOT будет отправлять сводку статистики — суммы по дням, топ приложений '
            'с названиями и временем, цель и серию — языковой модели Ollama, '
            'запущенной на этом компьютере (127.0.0.1). Сырые сессии, заголовки окон '
            'и содержимое не передаются. В интернет ничего не уходит.\n\n'
            'Ollama — отдельная программа, которую вы устанавливаете сами; REBOOT её '
            'не контролирует. Советы модели могут быть неточными.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Включить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _c.setLocalAi(enabled: true, model: _c.choices.localAiModel);
    await _check();
  }

  Future<void> _ask() async {
    final model = _c.choices.localAiModel;
    if (model == null) return;
    setState(() {
      _busy = true;
      _advice = null;
    });
    final data = _data();
    try {
      final text = await _ai.advise(
        model: model,
        summary: buildAiSummary(
          week: data.week,
          streak: _c.streakSummary(today: widget.today),
          heatmap: data.heatmap,
        ),
      );
      setState(() => _advice = text);
    } on LocalAiException catch (error) {
      setState(() => _status = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _c,
    builder: (context, _) {
      final palette = context.palette;
      final enabled = _c.choices.localAiEnabled;
      final model = _c.choices.localAiModel;
      final demo = _c.mode == UsageDataMode.demo;
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 17,
                  color: palette.accent,
                ),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'Локальный ИИ-помощник',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                if (demo) ModeBadge(mode: _c.mode, compact: true),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Советы от языковой модели, которая работает на этом компьютере через Ollama. '
              'Данные не покидают устройство. Выключено по умолчанию.',
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            Material(
              color: Colors.transparent,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Использовать локальную модель',
                  style: TextStyle(fontSize: 13),
                ),
                value: enabled,
                onChanged: _busy
                    ? null
                    : (v) => v
                          ? _enable()
                          : _c.setLocalAi(enabled: false, model: model),
              ),
            ),
            if (enabled) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _check,
                    icon: const Icon(Icons.search_rounded, size: 16),
                    label: const Text('Проверить Ollama'),
                  ),
                  if (_models != null && _models!.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _models!.contains(model)
                            ? model
                            : _models!.first,
                        onChanged: (v) =>
                            _c.setLocalAi(enabled: true, model: v),
                        items: [
                          for (final m in _models!)
                            DropdownMenuItem(
                              value: m,
                              child: Text(m, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: _busy || model == null || _models == null
                        ? null
                        : _ask,
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: const Text('Получить советы'),
                  ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (_status != null) ...[
                const SizedBox(height: 8),
                Text(
                  _status!,
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
              ],
              if (_advice != null) ...[
                const SizedBox(height: 12),
                Eyebrow(
                  demo
                      ? 'Советы модели · по демо-данным'
                      : 'Советы модели · $model',
                ),
                const SizedBox(height: 6),
                SelectableText(
                  _advice!,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 6),
                Text(
                  'Ответ модели может быть неточным. Это не медицинская рекомендация.',
                  style: TextStyle(color: palette.muted, fontSize: 10),
                ),
              ],
            ],
            const Divider(height: 24),
            Row(
              children: [
                const Expanded(child: Eyebrow('Советы без ИИ')),
                TextButton(
                  onPressed: () {
                    final data = _data();
                    setState(
                      () => _ruleTips = ruleBasedTips(
                        week: data.week,
                        heatmap: data.heatmap,
                      ),
                    );
                  },
                  child: const Text('Показать'),
                ),
              ],
            ),
            if (_ruleTips != null)
              for (var i = 0; i < _ruleTips!.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${i + 1}. ${_ruleTips![i]}',
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                ),
            if (_ruleTips != null && demo)
              Text(
                'Посчитано по демо-данным.',
                style: TextStyle(color: palette.muted, fontSize: 10),
              ),
          ],
        ),
      );
    },
  );
}
