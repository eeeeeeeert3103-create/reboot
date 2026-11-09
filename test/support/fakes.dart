import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/widgets/navigation.dart';
import 'package:reboot_app/models/collector_models.dart';
import 'package:reboot_app/services/consent_store.dart';
import 'package:reboot_app/services/user_settings_store.dart';

/// Scriptable collector for tests: queue events, then drain them.
class FakeCollector implements UsageCollector {
  FakeCollector({this.available = true, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  bool available;
  final DateTime Function() _clock;
  final pending = <UsageEvent>[];
  bool collecting = false;
  bool everStarted = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<CollectorStatus> getStatus() async => CollectorStatus(
    platform: CollectorPlatform.macOS,
    lifecycle: !available
        ? CollectorLifecycle.unavailable
        : collecting
        ? CollectorLifecycle.collecting
        : (everStarted ? CollectorLifecycle.stopped : CollectorLifecycle.ready),
    permissionGranted: available,
    collecting: collecting,
    message: collecting ? 'Сбор идёт' : 'Сбор не идёт',
    checkedAt: _clock(),
  );

  @override
  Future<CollectorStatus> requestPermission() => getStatus();

  @override
  Future<void> start({required bool userConsent}) async {
    if (!userConsent) throw StateError('consent_required');
    startCalls++;
    collecting = true;
    everStarted = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    collecting = false;
  }

  @override
  Future<CollectorSnapshot> drainEvents() async {
    final events = [...pending];
    pending.clear();
    var captured = _clock();
    for (final e in events) {
      if (e.timestamp.isAfter(captured)) captured = e.timestamp;
    }
    return CollectorSnapshot(
      platform: CollectorPlatform.macOS,
      capturedAt: captured,
      events: events,
    );
  }

  void foreground(String app, DateTime end, int seconds) => pending.add(
    UsageEvent(
      type: UsageEventType.foregroundEnded,
      timestamp: end,
      appIdentifier: app,
      displayName: app,
      durationSeconds: seconds,
    ),
  );
}

ConsentStore onboardedDemo() =>
    ConsentStore.inMemory(const PrivacyChoices(onboardingCompleted: true));

ConsentStore onboardedReal() => ConsentStore.inMemory(
  const PrivacyChoices(
    onboardingCompleted: true,
    collectionConsent: true,
    preferRealData: true,
  ),
);

/// Opens a section the way a user would: sidebar on wide windows, bottom
/// bar or its «Ещё» sheet on narrow ones.
Future<void> openSection(WidgetTester tester, String label) async {
  final bar = find.byType(NavigationBar);
  if (bar.evaluate().isEmpty) {
    await tester.tap(
      find.descendant(
        of: find.byType(AppSidebar),
        matching: find.text(label == 'Профиль' ? 'Профиль и настройки' : label),
      ),
    );
  } else {
    final inBar = find.descendant(of: bar, matching: find.text(label));
    if (inBar.evaluate().isNotEmpty) {
      await tester.tap(inBar);
    } else {
      await tester.tap(find.descendant(of: bar, matching: find.text('Ещё')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(ListTile), matching: find.text(label)),
      );
    }
  }
  await tester.pumpAndSettle();
}

/// Settings through the mocked `reboot/settings` channel on every host.
/// (Without an explicit channel, Windows would use a real settings file.)
UserSettingsStore testSettingsStore() =>
    UserSettingsStore(channel: const MethodChannel('reboot/settings'));
