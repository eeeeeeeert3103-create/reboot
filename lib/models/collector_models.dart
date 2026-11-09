enum CollectorPlatform { macOS, windows, unsupported }

enum CollectorLifecycle {
  unavailable,
  permissionRequired,
  ready,
  collecting,
  stopped,
  failed,
}

enum UsageEventType {
  foregroundStarted,
  foregroundEnded,
  appLaunched,
  idleStarted,
  idleEnded,
  sessionLocked,
  sessionUnlocked,
}

class CollectorStatus {
  const CollectorStatus({
    required this.platform,
    required this.lifecycle,
    required this.permissionGranted,
    required this.collecting,
    required this.message,
    required this.checkedAt,
  });

  final CollectorPlatform platform;
  final CollectorLifecycle lifecycle;
  final bool permissionGranted;
  final bool collecting;
  final String message;
  final DateTime checkedAt;

  bool get isAvailable => lifecycle != CollectorLifecycle.unavailable;

  Map<String, Object?> toMap() => {
    'platform': platform.name,
    'lifecycle': lifecycle.name,
    'permissionGranted': permissionGranted,
    'collecting': collecting,
    'message': message,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };

  factory CollectorStatus.fromMap(Map<Object?, Object?> map) {
    final platform = _enumByName(CollectorPlatform.values, map['platform']);
    final lifecycle = _enumByName(CollectorLifecycle.values, map['lifecycle']);
    final permission = map['permissionGranted'];
    final collecting = map['collecting'];
    final message = map['message'];
    final checkedAt = map['checkedAt'];

    if (platform == null ||
        lifecycle == null ||
        permission is! bool ||
        collecting is! bool ||
        message is! String ||
        checkedAt is! String) {
      throw const FormatException('Invalid collector status.');
    }

    final date = DateTime.tryParse(checkedAt);
    if (date == null ||
        (collecting && lifecycle != CollectorLifecycle.collecting)) {
      throw const FormatException('Invalid collector status values.');
    }

    return CollectorStatus(
      platform: platform,
      lifecycle: lifecycle,
      permissionGranted: permission,
      collecting: collecting,
      message: message,
      checkedAt: date,
    );
  }
}

class UsageEvent {
  UsageEvent({
    required this.type,
    required this.timestamp,
    this.appIdentifier,
    this.displayName,
    this.durationSeconds,
  }) {
    if (appIdentifier != null && appIdentifier!.trim().isEmpty) {
      throw ArgumentError.value(appIdentifier, 'appIdentifier');
    }
    if (displayName != null && displayName!.trim().isEmpty) {
      throw ArgumentError.value(displayName, 'displayName');
    }
    if (durationSeconds != null && durationSeconds! < 0) {
      throw ArgumentError.value(durationSeconds, 'durationSeconds');
    }
    if (type != UsageEventType.foregroundEnded && durationSeconds != null) {
      throw ArgumentError('Duration only applies to foregroundEnded.');
    }
  }

  final UsageEventType type;
  final DateTime timestamp;
  final String? appIdentifier;
  final String? displayName;
  final int? durationSeconds;

  Map<String, Object?> toMap() => {
    'type': type.name,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (appIdentifier != null) 'appIdentifier': appIdentifier,
    if (displayName != null) 'displayName': displayName,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
  };

  factory UsageEvent.fromMap(Map<Object?, Object?> map) {
    final type = _enumByName(UsageEventType.values, map['type']);
    final timestamp = map['timestamp'];
    final app = map['appIdentifier'];
    final display = map['displayName'];
    final duration = map['durationSeconds'];

    if (type == null ||
        timestamp is! String ||
        (app != null && app is! String) ||
        (display != null && display is! String) ||
        (duration != null && duration is! int)) {
      throw const FormatException('Invalid usage event.');
    }

    final date = DateTime.tryParse(timestamp);
    if (date == null) {
      throw const FormatException('Invalid usage event timestamp.');
    }

    try {
      return UsageEvent(
        type: type,
        timestamp: date,
        appIdentifier: app as String?,
        displayName: display as String?,
        durationSeconds: duration as int?,
      );
    } on ArgumentError {
      throw const FormatException('Invalid usage event values.');
    }
  }
}

class CollectorSnapshot {
  CollectorSnapshot({
    required this.platform,
    required this.capturedAt,
    required List<UsageEvent> events,
  }) : events = List.unmodifiable(events) {
    if (platform == CollectorPlatform.unsupported) {
      throw ArgumentError('Unsupported platform.');
    }
    if (this.events.any((event) => event.timestamp.isAfter(capturedAt))) {
      throw ArgumentError('Event timestamp is after snapshot capture.');
    }
  }

  final CollectorPlatform platform;
  final DateTime capturedAt;
  final List<UsageEvent> events;

  Map<String, Object?> toMap() => {
    'platform': platform.name,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'events': events.map((event) => event.toMap()).toList(),
  };

  factory CollectorSnapshot.fromMap(Map<Object?, Object?> map) {
    final platform = _enumByName(CollectorPlatform.values, map['platform']);
    final captured = map['capturedAt'];
    final rawEvents = map['events'];

    if (platform == null ||
        platform == CollectorPlatform.unsupported ||
        captured is! String ||
        rawEvents is! List) {
      throw const FormatException('Invalid collector snapshot.');
    }

    final date = DateTime.tryParse(captured);
    if (date == null) {
      throw const FormatException('Invalid snapshot timestamp.');
    }

    final events = <UsageEvent>[];
    for (final raw in rawEvents) {
      if (raw is! Map<Object?, Object?>) {
        throw const FormatException('Invalid snapshot event.');
      }
      events.add(UsageEvent.fromMap(raw));
    }

    try {
      return CollectorSnapshot(
        platform: platform,
        capturedAt: date,
        events: events,
      );
    } on ArgumentError {
      throw const FormatException('Invalid snapshot values.');
    }
  }
}

/// Platform collector behind the `reboot/collector` channel.
///
/// See `docs/collector-contract.md` for the exact event rules.
abstract interface class UsageCollector {
  Future<CollectorStatus> getStatus();
  Future<CollectorStatus> requestPermission();
  Future<void> start({required bool userConsent});
  Future<void> stop();

  /// Returns and clears every buffered event. While collecting, the open
  /// foreground segment is checkpointed first, so at most one poll interval
  /// can be lost if the app is killed.
  Future<CollectorSnapshot> drainEvents();
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
