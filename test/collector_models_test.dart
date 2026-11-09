import 'package:flutter_test/flutter_test.dart';
import 'package:reboot_app/models/collector_models.dart';

void main() {
  test('usage event round trip', () {
    final event = UsageEvent(
      type: UsageEventType.foregroundEnded,
      timestamp: DateTime.utc(2026, 11, 1, 12),
      appIdentifier: 'com.example.editor',
      durationSeconds: 120,
    );
    final restored = UsageEvent.fromMap(event.toMap());

    expect(restored.type, event.type);
    expect(restored.timestamp, event.timestamp);
    expect(restored.appIdentifier, event.appIdentifier);
    expect(restored.durationSeconds, 120);
  });

  test('negative duration is rejected', () {
    expect(
      () => UsageEvent(
        type: UsageEventType.foregroundEnded,
        timestamp: DateTime.utc(2026),
        durationSeconds: -1,
      ),
      throwsArgumentError,
    );
  });

  test('duration on app launch is rejected', () {
    expect(
      () => UsageEvent(
        type: UsageEventType.appLaunched,
        timestamp: DateTime.utc(2026),
        durationSeconds: 1,
      ),
      throwsArgumentError,
    );
  });

  test('collector status round trip', () {
    final status = CollectorStatus(
      platform: CollectorPlatform.macOS,
      lifecycle: CollectorLifecycle.ready,
      permissionGranted: true,
      collecting: false,
      message: 'Ready',
      checkedAt: DateTime.utc(2026, 11, 1),
    );

    final restored = CollectorStatus.fromMap(status.toMap());
    expect(restored.platform, CollectorPlatform.macOS);
    expect(restored.lifecycle, CollectorLifecycle.ready);
    expect(restored.isAvailable, isTrue);
  });

  test('inconsistent collector status is rejected', () {
    expect(
      () => CollectorStatus.fromMap({
        'platform': 'windows',
        'lifecycle': 'ready',
        'permissionGranted': true,
        'collecting': true,
        'message': 'Invalid',
        'checkedAt': '2026-11-01T12:00:00Z',
      }),
      throwsFormatException,
    );
  });

  test('snapshot round trip', () {
    final snapshot = CollectorSnapshot(
      platform: CollectorPlatform.windows,
      capturedAt: DateTime.utc(2026, 11, 1, 12, 1),
      events: [
        UsageEvent(
          type: UsageEventType.appLaunched,
          timestamp: DateTime.utc(2026, 11, 1, 12),
          appIdentifier: 'editor.exe',
        ),
      ],
    );

    final restored = CollectorSnapshot.fromMap(snapshot.toMap());
    expect(restored.platform, CollectorPlatform.windows);
    expect(restored.events, hasLength(1));
    expect(restored.events.single.appIdentifier, 'editor.exe');
  });

  test('snapshot rejects future events', () {
    expect(
      () => CollectorSnapshot(
        platform: CollectorPlatform.macOS,
        capturedAt: DateTime.utc(2026, 11, 1),
        events: [
          UsageEvent(
            type: UsageEventType.appLaunched,
            timestamp: DateTime.utc(2026, 11, 2),
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('unsupported platform cannot create snapshot', () {
    expect(
      () => CollectorSnapshot(
        platform: CollectorPlatform.unsupported,
        capturedAt: DateTime.utc(2026, 11, 1),
        events: const [],
      ),
      throwsArgumentError,
    );
  });
}
