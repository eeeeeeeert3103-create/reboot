import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native window, menu bar / tray and login-item state.
/// See `docs/app-shell-contract.md`.
class AppShellState {
  const AppShellState({
    this.available = false,
    this.backgroundMode = false,
    this.windowVisible = true,
    this.launchAtLogin = false,
    this.launchAtLoginStatus = 'notSupported',
    this.launchAtLoginMessage = '',
    this.startedInBackground = false,
    this.trayAvailable = false,
  });

  /// `false` when the native side is missing (tests, unsupported platforms).
  final bool available;
  final bool backgroundMode;
  final bool windowVisible;
  final bool launchAtLogin;
  final String launchAtLoginStatus;
  final String launchAtLoginMessage;
  final bool startedInBackground;
  final bool trayAvailable;

  bool get launchAtLoginSupported =>
      available && launchAtLoginStatus != 'notSupported';

  factory AppShellState.fromMap(Map<Object?, Object?> map) {
    bool flag(String key) => map[key] == true;
    String text(String key, String fallback) =>
        map[key] is String ? map[key]! as String : fallback;
    return AppShellState(
      available: true,
      backgroundMode: flag('backgroundMode'),
      windowVisible: map['windowVisible'] != false,
      launchAtLogin: flag('launchAtLogin'),
      launchAtLoginStatus: text('launchAtLoginStatus', 'error'),
      launchAtLoginMessage: text('launchAtLoginMessage', ''),
      startedInBackground: flag('startedInBackground'),
      trayAvailable: flag('trayAvailable'),
    );
  }
}

enum TrayAction { open, toggleCollection, quit }

class AppShellBridge extends ChangeNotifier {
  AppShellBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('reboot/app') {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  AppShellState _state = const AppShellState();
  String? _lastStatus;
  String? lastError;

  /// Set by the app: what to do when the user picks a tray / menu bar item.
  Future<void> Function(TrayAction action)? onTrayAction;

  AppShellState get state => _state;

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'trayAction':
        final args = call.arguments;
        final name = args is Map ? args['action'] : null;
        final action = TrayAction.values.where((a) => a.name == name);
        if (action.isNotEmpty) await onTrayAction?.call(action.single);
      case 'windowVisibilityChanged':
        final args = call.arguments;
        _state = AppShellState(
          available: _state.available,
          backgroundMode: _state.backgroundMode,
          windowVisible: args is Map && args['visible'] == true,
          launchAtLogin: _state.launchAtLogin,
          launchAtLoginStatus: _state.launchAtLoginStatus,
          launchAtLoginMessage: _state.launchAtLoginMessage,
          startedInBackground: _state.startedInBackground,
          trayAvailable: _state.trayAvailable,
        );
        notifyListeners();
    }
    return null;
  }

  Future<AppShellState> _call(String method, [Object? args]) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        method,
        args,
      );
      if (raw != null) _state = AppShellState.fromMap(raw);
      lastError = null;
    } on MissingPluginException {
      _state = const AppShellState();
    } on PlatformException catch (error) {
      lastError = error.message ?? 'Системная ошибка.';
    }
    notifyListeners();
    return _state;
  }

  Future<AppShellState> refresh() => _call('getAppState');

  Future<AppShellState> setBackgroundMode(bool enabled) =>
      _call('setBackgroundMode', {'enabled': enabled});

  Future<AppShellState> setLaunchAtLogin(bool enabled) =>
      _call('setLaunchAtLogin', {'enabled': enabled});

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No native shell (tests or unsupported platform).
    } on PlatformException catch (error) {
      lastError = error.message;
    }
  }

  /// Sends the menu bar / tray text; skipped when nothing changed.
  Future<void> updateStatus({
    required String title,
    required List<String> lines,
    required bool collecting,
    double? progress,
  }) async {
    if (!_state.available) return;
    final key = '$title|${lines.join('|')}|$collecting';
    if (key == _lastStatus) return;
    _lastStatus = key;
    await _invoke('updateStatus', {
      'title': title,
      'lines': lines,
      'collecting': collecting,
      'progress': ?progress,
    });
  }

  /// Current foreground app (collector identifiers), or `null`.
  Future<({String appId, String name})?> frontmostApp() async {
    if (!_state.available) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getFrontmostApp',
      );
      final id = raw?['appIdentifier'];
      if (id is! String || id.isEmpty) return null;
      final name = raw?['displayName'];
      return (appId: id, name: name is String ? name : id);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Soft limit: hides / minimises [appId] if it is in front.
  Future<({bool applied, String message})> limitApp(String appId) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('limitApp', {
        'appIdentifier': appId,
      });
      return (
        applied: raw?['applied'] == true,
        message: raw?['message'] is String ? raw!['message']! as String : '',
      );
    } on MissingPluginException {
      return (applied: false, message: 'Ограничение недоступно в этой сборке.');
    } on PlatformException catch (error) {
      return (applied: false, message: error.message ?? 'Системная ошибка.');
    }
  }

  Future<void> showWindow() => _invoke('showWindow');
  Future<void> hideWindow() => _invoke('hideWindow');
  Future<void> quit() => _invoke('quit');

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
