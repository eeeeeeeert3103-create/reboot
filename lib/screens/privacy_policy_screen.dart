import 'package:flutter/material.dart';

import '../content/privacy_policy.dart';
import '../theme/reboot_themes.dart';
import '../widgets/app_card.dart';
import '../widgets/ui_kit.dart';

/// The in-app copy of `docs/privacy-policy.md`.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()));

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('Политика конфиденциальности'),
      ),
      body: PageFrame(
        maxWidth: 820,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
          children: [
            Eyebrow('Версия $privacyPolicyVersion · черновик'),
            const SizedBox(height: 8),
            Text(
              'Документ описывает фактическую работу этой версии REBOOT. Юридические реквизиты ещё не заполнены и отмечены в тексте.',
              style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: Gap.l),
            for (final section in privacyPolicySections) ...[
              Text(
                section.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              for (final paragraph in section.paragraphs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText(
                    paragraph,
                    style: const TextStyle(fontSize: 13, height: 1.55),
                  ),
                ),
              const SizedBox(height: Gap.m),
            ],
          ],
        ),
      ),
    );
  }
}
