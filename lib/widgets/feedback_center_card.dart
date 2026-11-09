import 'package:flutter/material.dart';

import '../services/privacy_data_store.dart';
import '../theme/reboot_themes.dart';
import 'app_card.dart';

class FeedbackCenterCard extends StatefulWidget {
  const FeedbackCenterCard({super.key, required this.dataStore});
  final PrivacyDataStore dataStore;

  @override
  State<FeedbackCenterCard> createState() => _FeedbackCenterCardState();
}

class _FeedbackCenterCardState extends State<FeedbackCenterCard> {
  final _controller = TextEditingController();
  int? _rating;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 17,
              color: context.palette.accent,
            ),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                'Центр обратной связи',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          widget.dataStore.canStoreFeedback
              ? 'Оставьте отзыв по желанию. Он хранится локально в данных приложения.'
              : (widget.dataStore.storageIssue ??
                    'Локальное сохранение отзыва недоступно на этой платформе.'),
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        const Text('Оценка (по желанию)', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 3),
        Wrap(
          spacing: 2,
          children: [
            for (var value = 1; value <= 5; value++)
              IconButton(
                tooltip: '$value из 5',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _rating = value),
                icon: Icon(
                  value <= (_rating ?? 0)
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: context.palette.accent,
                ),
              ),
          ],
        ),
        TextField(
          controller: _controller,
          maxLength: 1000,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Ваш отзыв',
            hintText: 'Что можно улучшить?',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: widget.dataStore.canStoreFeedback ? _save : null,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Сохранить отзыв на этом устройстве'),
        ),
        if (widget.dataStore.feedback.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            'Сохранено отзывов: ${widget.dataStore.feedback.length}',
            style: TextStyle(color: context.palette.muted, fontSize: 11),
          ),
        ],
      ],
    ),
  );

  Future<void> _save() async {
    final message = _controller.text.trim();
    if (message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Напишите отзыв, чтобы сохранить его.')),
      );
      return;
    }
    try {
      await widget.dataStore.saveFeedback(
        LocalFeedback(
          message: message,
          rating: _rating,
          createdAt: DateTime.now(),
        ),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить отзыв локально.')),
      );
      setState(() {});
      return;
    }
    if (!mounted) return;
    _controller.clear();
    setState(() => _rating = null);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Отзыв сохранён локально.')));
  }
}
