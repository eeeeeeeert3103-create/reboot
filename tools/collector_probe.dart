// Developer smoke test for the native collector channel. Not part of the app.
// Run: flutter run -d macos -t tools/collector_probe.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:reboot_app/services/collector_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('REBOOT collector probe'))),
    ),
  );
  final collector = MethodChannelUsageCollector();
  final before = await collector.getStatus();
  print('PROBE status: ${before.lifecycle.name} | ${before.message}');
  try {
    await collector.start(userConsent: false);
  } on CollectorException catch (e) {
    print('PROBE without consent: ${e.code}');
  }
  await collector.start(userConsent: true);
  print('PROBE status: ${(await collector.getStatus()).lifecycle.name}');
  await Future<void>.delayed(const Duration(seconds: 4));
  final snapshot = await collector.drainEvents();
  for (final e in snapshot.events) {
    print(
      'PROBE event: ${e.type.name} ${e.appIdentifier ?? ''} ${e.durationSeconds ?? ''}',
    );
  }
  await collector.stop();
  final after = await collector.drainEvents();
  print('PROBE after stop: ${after.events.map((e) => e.type.name).join(',')}');
  print('PROBE status: ${(await collector.getStatus()).lifecycle.name} | done');
  exit(0);
}
