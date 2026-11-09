import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests have no native window shell; answer `reboot/app` with `null` so
/// the app treats it as unavailable instead of waiting on the real engine.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('reboot/app'),
        (_) async => null,
      );
  await testMain();
}
