import 'dart:io';

import 'package:flutter/services.dart';

import 'privacy_data_store.dart';

/// Saves the user's export file.
///
/// macOS: the system save panel via `reboot/files` (sandbox allows writing
/// only where the user chose). Windows: `Documents\REBOOT`.
class DataExporter {
  DataExporter({
    required this._privacyStore,
    MethodChannel? filesChannel,
    bool? useSavePanel,
  }) : _channel = filesChannel ?? const MethodChannel('reboot/files'),
       _useSavePanel = useSavePanel ?? Platform.isMacOS;

  final PrivacyDataStore _privacyStore;
  final MethodChannel _channel;
  final bool _useSavePanel;

  bool get canExport => _useSavePanel || _privacyStore.canExportFile;

  String get unavailableReason =>
      _useSavePanel ? '' : _privacyStore.exportUnavailableReason;

  /// Returns the saved path, or `null` when the user cancelled.
  Future<String?> save(String suggestedName, String content) async {
    if (_useSavePanel) {
      try {
        return await _channel.invokeMethod<String>('saveTextFile', {
          'suggestedName': suggestedName,
          'content': content,
        });
      } on MissingPluginException {
        throw const PrivacyStorageUnavailable(
          'Диалог сохранения недоступен в этой сборке.',
        );
      } on PlatformException catch (error) {
        throw PrivacyStorageUnavailable(
          error.message ?? 'Не удалось сохранить файл экспорта.',
        );
      }
    }
    final file = await _privacyStore.writeExportFile(suggestedName, content);
    return file.path;
  }
}
