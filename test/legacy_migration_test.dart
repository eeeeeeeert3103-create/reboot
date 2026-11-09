import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/services/privacy_data_store.dart';

void main() {
  test('legacy nested macOS folder is moved without overwriting', () async {
    final root = await Directory.systemTemp.createTemp('reboot-migrate-');
    addTearDown(() => root.delete(recursive: true));
    final legacy = Directory('${root.path}/legacy')..createSync();
    final target = Directory('${root.path}/target')..createSync();
    File('${legacy.path}/feedback.json').writeAsStringSync(
      '{"version":1,"feedback":[{"message":"old","createdAt":"2026-11-01T00:00:00.000Z"}]}',
    );
    File('${legacy.path}/streak.json').writeAsStringSync('legacy');
    File('${target.path}/streak.json').writeAsStringSync('current');

    final store = PrivacyDataStore(
      appDataDirectory: target,
      legacyAppDataDirectory: legacy,
    );
    await store.loadFeedback();

    expect(store.feedback.single.message, 'old');
    expect(File('${target.path}/streak.json').readAsStringSync(), 'current');
    expect(File('${legacy.path}/streak.json').existsSync(), isTrue);
    expect(File('${legacy.path}/feedback.json').existsSync(), isFalse);
  });
}
