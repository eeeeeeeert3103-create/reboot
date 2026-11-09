import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/services/consent_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reboot-consent-');
  });
  tearDown(() => directory.delete(recursive: true));

  File file() => File('${directory.path}/${ConsentStore.fileName}');

  test('defaults to no consent, DEMO and onboarding pending', () async {
    final choices = await ConsentStore(directory: directory).load();
    expect(choices.collectionConsent, isFalse);
    expect(choices.wantsCollection, isFalse);
    expect(choices.onboardingCompleted, isFalse);
  });

  test('choices survive reopening', () async {
    final store = ConsentStore(directory: directory);
    await store.load();
    final saved = PrivacyChoices(
      collectionConsent: true,
      consentChangedAt: DateTime.utc(2026, 11, 5, 9),
      policyVersion: '2026-11-05',
      preferRealData: true,
      onboardingCompleted: true,
    );
    await store.save(saved);
    expect(await ConsentStore(directory: directory).load(), saved);
  });

  test('an unreadable file means no consent and is not overwritten', () async {
    file().writeAsStringSync('not json');
    final store = ConsentStore(directory: directory);
    final choices = await store.load();
    expect(choices.collectionConsent, isFalse);
    expect(store.issue, isNotNull);
    expect(file().readAsStringSync(), 'not json');
  });

  test('clear deletes the file and resets choices', () async {
    final store = ConsentStore(directory: directory);
    await store.save(const PrivacyChoices(collectionConsent: true));
    await store.clear();
    expect(file().existsSync(), isFalse);
    expect(store.choices.collectionConsent, isFalse);
  });
}
