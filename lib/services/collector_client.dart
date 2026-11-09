import 'dart:io';

import 'package:flutter/services.dart';

import '../models/collector_models.dart';

class CollectorException implements Exception {
  const CollectorException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'CollectorException($code): $message';
}

/// Dart side of the `reboot/collector` channel implemented in Swift (macOS)
/// and C++ (Windows). Other platforms report [CollectorLifecycle.unavailable].
class MethodChannelUsageCollector implements UsageCollector {
  MethodChannelUsageCollector({
    MethodChannel? channel,
    CollectorPlatform? platform,
    DateTime Function()? clock,
  }) : _channel = channel ?? const MethodChannel('reboot/collector'),
       platform = platform ?? _currentPlatform(),
       _clock = clock ?? DateTime.now;

  final MethodChannel _channel;
  final CollectorPlatform platform;
  final DateTime Function() _clock;

  static CollectorPlatform _currentPlatform() {
    if (Platform.isMacOS) return CollectorPlatform.macOS;
    if (Platform.isWindows) return CollectorPlatform.windows;
    return CollectorPlatform.unsupported;
  }

  bool get isSupported => platform != CollectorPlatform.unsupported;

  CollectorStatus _unavailable(String message) => CollectorStatus(
    platform: platform,
    lifecycle: CollectorLifecycle.unavailable,
    permissionGranted: false,
    collecting: false,
    message: message,
    checkedAt: _clock(),
  );

  @override
  Future<CollectorStatus> getStatus() => _status('getStatus');

  @override
  Future<CollectorStatus> requestPermission() => _status('requestPermission');

  Future<CollectorStatus> _status(String method) async {
    if (!isSupported) {
      return _unavailable(
        'Сбор статистики доступен только на macOS и Windows.',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(method);
      if (raw == null) throw const FormatException('Empty collector status.');
      return CollectorStatus.fromMap(raw);
    } on MissingPluginException {
      return _unavailable('Сборщик статистики не встроен в эту сборку.');
    } on PlatformException catch (error) {
      return CollectorStatus(
        platform: platform,
        lifecycle: CollectorLifecycle.failed,
        permissionGranted: false,
        collecting: false,
        message: error.message ?? 'Сборщик статистики вернул ошибку.',
        checkedAt: _clock(),
      );
    } on FormatException {
      return CollectorStatus(
        platform: platform,
        lifecycle: CollectorLifecycle.failed,
        permissionGranted: false,
        collecting: false,
        message: 'Сборщик вернул некорректный статус.',
        checkedAt: _clock(),
      );
    }
  }

  @override
  Future<void> start({required bool userConsent}) async {
    if (!userConsent) {
      throw const CollectorException(
        'consent_required',
        'Сбор статистики не запускается без согласия.',
      );
    }
    await _invoke('start', {'userConsent': true});
  }

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Future<CollectorSnapshot> drainEvents() async {
    if (!isSupported) {
      throw const CollectorException('unavailable', 'Сборщик недоступен.');
    }
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<Object?, Object?>('drainEvents');
    } on MissingPluginException {
      throw const CollectorException('unavailable', 'Сборщик недоступен.');
    } on PlatformException catch (error) {
      throw CollectorException(error.code, error.message ?? 'Ошибка сборщика.');
    }
    if (raw == null) {
      throw const CollectorException('invalid', 'Пустой ответ сборщика.');
    }
    return CollectorSnapshot.fromMap(raw);
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!isSupported) {
      throw const CollectorException('unavailable', 'Сборщик недоступен.');
    }
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      throw const CollectorException('unavailable', 'Сборщик недоступен.');
    } on PlatformException catch (error) {
      throw CollectorException(error.code, error.message ?? 'Ошибка сборщика.');
    }
  }
}
