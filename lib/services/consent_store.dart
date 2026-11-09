import 'dart:convert';
import 'dart:io';

/// The user's privacy choices: consent to usage collection, which data mode
/// they prefer and whether onboarding was completed.
class PrivacyChoices {
  const PrivacyChoices({
    this.collectionConsent = false,
    this.consentChangedAt,
    this.policyVersion,
    this.preferRealData = false,
    this.onboardingCompleted = false,
    this.backgroundCollection = true,
    this.localAiEnabled = false,
    this.localAiModel,
  });

  static const initial = PrivacyChoices();

  /// Explicit consent to collect usage statistics on this device.
  final bool collectionConsent;
  final DateTime? consentChangedAt;

  /// Privacy policy version shown when consent was last changed.
  final String? policyVersion;

  /// The user wants REAL data; it is used only together with consent.
  final bool preferRealData;
  final bool onboardingCompleted;

  /// Keep collecting in the menu bar / tray after the window is closed.
  final bool backgroundCollection;

  /// Explicit opt-in to send a usage summary to a model on this computer.
  final bool localAiEnabled;
  final String? localAiModel;

  bool get wantsCollection => collectionConsent && preferRealData;

  PrivacyChoices copyWith({
    bool? collectionConsent,
    DateTime? consentChangedAt,
    String? policyVersion,
    bool? preferRealData,
    bool? onboardingCompleted,
    bool? backgroundCollection,
    bool? localAiEnabled,
    String? localAiModel,
  }) => PrivacyChoices(
    collectionConsent: collectionConsent ?? this.collectionConsent,
    consentChangedAt: consentChangedAt ?? this.consentChangedAt,
    policyVersion: policyVersion ?? this.policyVersion,
    preferRealData: preferRealData ?? this.preferRealData,
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    backgroundCollection: backgroundCollection ?? this.backgroundCollection,
    localAiEnabled: localAiEnabled ?? this.localAiEnabled,
    localAiModel: localAiModel ?? this.localAiModel,
  );

  Map<String, Object?> toMap() => {
    'version': 1,
    'collectionConsent': collectionConsent,
    'consentChangedAt': consentChangedAt?.toUtc().toIso8601String(),
    'policyVersion': policyVersion,
    'preferRealData': preferRealData,
    'onboardingCompleted': onboardingCompleted,
    'backgroundCollection': backgroundCollection,
    'localAiEnabled': localAiEnabled,
    'localAiModel': localAiModel,
  };

  factory PrivacyChoices.fromMap(Map<Object?, Object?> map) {
    if (map['version'] != 1) {
      throw const FormatException('Unsupported consent format.');
    }
    bool flag(String key) => map[key] is bool ? map[key]! as bool : false;
    final changed = map['consentChangedAt'];
    final policy = map['policyVersion'];
    return PrivacyChoices(
      collectionConsent: flag('collectionConsent'),
      consentChangedAt: changed is String ? DateTime.tryParse(changed) : null,
      policyVersion: policy is String ? policy : null,
      preferRealData: flag('preferRealData'),
      onboardingCompleted: flag('onboardingCompleted'),
      // Older files have no key: keep the default (on).
      backgroundCollection: map['backgroundCollection'] != false,
      localAiEnabled: flag('localAiEnabled'),
      localAiModel: map['localAiModel'] is String
          ? map['localAiModel']! as String
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PrivacyChoices &&
      other.collectionConsent == collectionConsent &&
      other.consentChangedAt == consentChangedAt &&
      other.policyVersion == policyVersion &&
      other.preferRealData == preferRealData &&
      other.onboardingCompleted == onboardingCompleted &&
      other.backgroundCollection == backgroundCollection &&
      other.localAiEnabled == localAiEnabled &&
      other.localAiModel == localAiModel;

  @override
  int get hashCode => Object.hash(
    collectionConsent,
    consentChangedAt,
    policyVersion,
    preferRealData,
    onboardingCompleted,
    backgroundCollection,
    localAiEnabled,
    localAiModel,
  );
}

/// Persists [PrivacyChoices] to `consent.json` in the app-data folder.
///
/// An unreadable file is treated as "no consent" so collection never starts
/// by accident, and is not overwritten until the user decides again.
class ConsentStore {
  ConsentStore({Directory? directory}) : this._(directory);

  ConsentStore.unavailable() : this._(null);

  /// Keeps choices in memory only; used by tests and previews.
  ConsentStore.inMemory([PrivacyChoices initial = PrivacyChoices.initial])
    : this._(null, initial);

  ConsentStore._(this._directory, [this._initial = PrivacyChoices.initial])
    : _choices = _initial;

  final PrivacyChoices _initial;

  final Directory? _directory;
  static const fileName = 'consent.json';

  PrivacyChoices _choices;
  String? _issue;

  PrivacyChoices get choices => _choices;
  bool get isAvailable => _directory != null;
  String? get issue => _issue;

  File? get _file {
    final directory = _directory;
    return directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  Future<PrivacyChoices> load() async {
    _issue = null;
    _choices = _initial;
    final file = _file;
    if (file == null || !await file.exists()) return _choices;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<Object?, Object?>) {
        throw const FormatException('Consent must be a JSON object.');
      }
      _choices = PrivacyChoices.fromMap(decoded);
    } on Object {
      _issue = 'Не удалось прочитать сохранённое согласие; сбор выключен.';
    }
    return _choices;
  }

  Future<void> save(PrivacyChoices choices) async {
    final directory = _directory;
    if (directory != null) {
      await directory.create(recursive: true);
      final file = _file!;
      final staging = File('${file.path}.new');
      await staging.writeAsString(
        const JsonEncoder.withIndent('  ').convert(choices.toMap()),
        flush: true,
      );
      await staging.rename(file.path);
    }
    _choices = choices;
    _issue = null;
  }

  Future<void> clear() async {
    final file = _file;
    if (file != null) {
      if (await file.exists()) await file.delete();
      final staging = File('${file.path}.new');
      if (await staging.exists()) await staging.delete();
    }
    _choices = PrivacyChoices.initial;
    _issue = null;
  }
}
