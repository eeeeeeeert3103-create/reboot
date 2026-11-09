import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/app.dart';
import 'package:reboot_app/services/privacy_data_store.dart';
import 'package:reboot_app/services/user_settings_store.dart';
import 'package:reboot_app/widgets/feedback_center_card.dart';
import 'package:reboot_app/widgets/privacy_center_card.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'readable export contains user data and excludes demo fixtures',
    () async {
      final appData = await Directory.systemTemp.createTemp(
        'reboot-readable-export-test-',
      );
      addTearDown(() => appData.delete(recursive: true));
      final store = PrivacyDataStore(appDataDirectory: appData);
      await store.loadFeedback();
      await store.saveFeedback(
        LocalFeedback(
          message: 'Please add a pause reminder',
          rating: 4,
          createdAt: DateTime.utc(2026, 11, 1),
        ),
      );

      final result = store.readableExport(
        const UserSettings(profileName: 'Taylor', goalHours: 5),
      );

      expect(result, contains('Taylor'));
      expect(result, contains('Please add a pause reminder'));
      expect(result, contains('No usage history stored'));
      expect(result, isNot(contains('Instagram')));
      expect(result, isNot(contains('totalMinutes')));
    },
  );

  test('file export creates a readable local JSON file', () async {
    final root = await Directory.systemTemp.createTemp('reboot-export-test-');
    addTearDown(() => root.delete(recursive: true));
    final appData = Directory('${root.path}/app-data');
    final documents = Directory('${root.path}/Documents/REBOOT');
    final store = PrivacyDataStore(
      appDataDirectory: appData,
      documentsDirectory: documents,
    );
    await store.loadFeedback();
    await store.saveFeedback(
      LocalFeedback(
        message: 'Keep feedback local',
        createdAt: DateTime.utc(2026, 11, 1),
      ),
    );

    final exportFile = await store.exportToDocuments(UserSettings.defaults);
    expect(exportFile.path, contains('reboot-privacy-export-'));
    expect(
      exportFile.path.replaceAll('\\', '/'),
      contains('/Documents/REBOOT/'),
    );
    expect(await exportFile.exists(), isTrue);
    expect(
      await exportFile.readAsString(),
      allOf(
        contains('No usage history stored'),
        contains('Keep feedback local'),
      ),
    );
  });

  test('feedback survives reopening the local data store', () async {
    final appData = await Directory.systemTemp.createTemp(
      'reboot-feedback-reopen-test-',
    );
    addTearDown(() => appData.delete(recursive: true));
    final firstStore = PrivacyDataStore(appDataDirectory: appData);
    await firstStore.loadFeedback();
    await firstStore.saveFeedback(
      LocalFeedback(
        message: 'Persist across launches',
        rating: 5,
        createdAt: DateTime.utc(2026, 11, 1, 10, 30),
      ),
    );

    final reopenedStore = PrivacyDataStore(appDataDirectory: appData);
    await reopenedStore.loadFeedback();

    expect(reopenedStore.feedback, hasLength(1));
    expect(reopenedStore.feedback.single.message, 'Persist across launches');
    expect(reopenedStore.feedback.single.rating, 5);
    expect(
      reopenedStore.feedback.single.createdAt,
      DateTime.utc(2026, 11, 1, 10, 30),
    );
  });

  test(
    'clearing feedback removes persisted records for the next launch',
    () async {
      final appData = await Directory.systemTemp.createTemp(
        'reboot-feedback-clear-test-',
      );
      addTearDown(() => appData.delete(recursive: true));
      final store = PrivacyDataStore(appDataDirectory: appData);
      await store.loadFeedback();
      await store.saveFeedback(
        LocalFeedback(
          message: 'Remove this record',
          createdAt: DateTime.utc(2026, 11, 1),
        ),
      );

      await store.clearFeedback();
      final reopenedStore = PrivacyDataStore(appDataDirectory: appData);
      await reopenedStore.loadFeedback();

      expect(reopenedStore.feedback, isEmpty);
    },
  );

  test(
    'unsupported storage reports unavailable instead of using a guessed path',
    () async {
      final store = PrivacyDataStore.unavailable();
      await store.loadFeedback();

      expect(store.canStoreFeedback, isFalse);
      expect(store.canExport, isFalse);
      expect(store.storageIssue, isNotNull);
    },
  );

  test('Windows paths use LOCALAPPDATA and USERPROFILE Documents', () {
    final store = PrivacyDataStore.forWindowsEnvironment({
      'LOCALAPPDATA': r'C:\Users\Taylor\AppData\Local',
      'USERPROFILE': r'C:\Users\Taylor',
    });

    expect(store.appDataDirectoryPath, r'C:\Users\Taylor\AppData\Local\REBOOT');
    expect(store.documentsDirectoryPath, r'C:\Users\Taylor\Documents\REBOOT');
  });

  test('missing Windows paths expose specific unavailable reasons', () async {
    final store = PrivacyDataStore.forWindowsEnvironment(const {});
    await store.loadFeedback();

    expect(store.canStoreFeedback, isFalse);
    expect(store.storageIssue, contains('LOCALAPPDATA'));
    expect(store.canExport, isFalse);
    expect(store.exportUnavailableReason, contains('USERPROFILE'));
  });

  testWidgets('local deletion requires confirmation and calls handler once', (
    tester,
  ) async {
    var deletionCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrivacyCenterCard(
            settings: UserSettings.defaults,
            dataStore: PrivacyDataStore(),
            onDelete: () async {
              deletionCount++;
              return LocalDataDeletionResult.complete;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Удалить все локальные данные'));
    await tester.pumpAndSettle();
    expect(deletionCount, 0);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(deletionCount, 0);

    await tester.tap(find.text('Удалить все локальные данные'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить').last);
    await tester.pumpAndSettle();
    expect(deletionCount, 1);
  });

  testWidgets('feedback form saves optional feedback through its store', (
    tester,
  ) async {
    final store = _TestPrivacyDataStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FeedbackCenterCard(dataStore: store)),
      ),
    );

    await tester.enterText(find.byType(TextField), 'A thoughtful note');
    await tester.tap(find.text('Сохранить отзыв на этом устройстве'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(store.feedback, hasLength(1));
    expect(store.feedback.single.message, 'A thoughtful note');
    expect(find.text('Отзыв сохранён локально.'), findsOneWidget);
  });

  testWidgets('confirmed deletion invokes deleteSettings and clears feedback', (
    tester,
  ) async {
    const channel = MethodChannel('reboot/settings');
    MethodCall? deletionCall;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deleteSettings') deletionCall = call;
      return UserSettings.defaults.toMap();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final privacyStore = _TrackingPrivacyDataStore();

    await tester.pumpWidget(
      RebootApp(
        settingsStore: UserSettingsStore(channel: channel),
        privacyDataStore: privacyStore,
        consentStore: onboardedDemo(),
        collector: FakeCollector(),
      ),
    );
    await tester.pumpAndSettle();
    await openSection(tester, 'Приватность');
    final deleteButton = find.text('Удалить все локальные данные');
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить').last);
    await tester.pumpAndSettle();

    expect(deletionCall?.method, 'deleteSettings');
    expect(privacyStore.feedbackWasCleared, isTrue);
    expect(find.text('Все локальные данные удалены.'), findsOneWidget);
  });

  testWidgets(
    'settings deletion failure keeps feedback and reports the partial',
    (tester) async {
      const channel = MethodChannel('reboot/settings');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'deleteSettings') {
          throw PlatformException(code: 'delete_failed');
        }
        return UserSettings.defaults.toMap();
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final privacyStore = _TrackingPrivacyDataStore();

      await tester.pumpWidget(
        RebootApp(
          settingsStore: UserSettingsStore(channel: channel),
          privacyDataStore: privacyStore,
          consentStore: onboardedDemo(),
          collector: FakeCollector(),
        ),
      );
      await tester.pumpAndSettle();
      await openSection(tester, 'Приватность');
      final deleteButton = find.text('Удалить все локальные данные');
      await tester.ensureVisible(deleteButton);
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
      await tester.pumpAndSettle();

      expect(privacyStore.feedbackWasCleared, isFalse);
      expect(
        find.text(
          'Не удалось подтвердить удаление настроек. Остальные данные оставлены.',
        ),
        findsOneWidget,
      );
    },
  );
}

class _TestPrivacyDataStore extends PrivacyDataStore {
  _TestPrivacyDataStore() : super.unavailable();

  final List<LocalFeedback> _items = [];

  @override
  List<LocalFeedback> get feedback => List.unmodifiable(_items);

  @override
  bool get canStoreFeedback => true;

  @override
  Future<void> saveFeedback(LocalFeedback feedback) async {
    _items.add(feedback);
  }
}

class _TrackingPrivacyDataStore extends PrivacyDataStore {
  _TrackingPrivacyDataStore() : super.unavailable();

  bool feedbackWasCleared = false;

  @override
  Future<void> clearFeedback() async {
    feedbackWasCleared = true;
  }
}
