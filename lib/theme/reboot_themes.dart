import 'package:flutter/material.dart';

/// Stable identifiers persisted in settings. Never rename existing values.
enum AppThemeId { dark, light, violet, midnightBlue, emerald }

/// Semantic color tokens shared by every screen, chart and dialog.
@immutable
class RebootPalette extends ThemeExtension<RebootPalette> {
  const RebootPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.accent,
    required this.accentSecondary,
    required this.onAccent,
    required this.success,
    required this.danger,
    required this.warning,
    required this.muted,
    required this.text,
    required this.textSecondary,
    required this.categoryColors,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color accent;
  final Color accentSecondary;
  final Color onAccent;
  final Color success;
  final Color danger;
  final Color warning;
  final Color muted;
  final Color text;
  final Color textSecondary;

  /// Social, work, video, other — in `UsageCategoryId` order.
  final List<Color> categoryColors;

  @override
  RebootPalette copyWith() => this;

  @override
  RebootPalette lerp(RebootPalette? other, double t) =>
      other == null || t < .5 ? this : other;
}

class RebootThemeDefinition {
  const RebootThemeDefinition({
    required this.id,
    required this.name,
    required this.palette,
  });

  final AppThemeId id;
  final String name;
  final RebootPalette palette;
}

/// Registry of available themes. A new theme is one entry here.
abstract final class RebootThemes {
  static const fallback = AppThemeId.dark;

  static const all = <RebootThemeDefinition>[
    RebootThemeDefinition(
      id: AppThemeId.dark,
      name: 'REBOOT Dark',
      palette: RebootPalette(
        brightness: Brightness.dark,
        background: Color(0xFF101114),
        surface: Color(0xFF191B21),
        surfaceRaised: Color(0xFF22252D),
        border: Color(0xFF30333D),
        accent: Color(0xFF9290F5),
        accentSecondary: Color(0xFF79A9E8),
        onAccent: Color(0xFF101114),
        success: Color(0xFF91B99A),
        danger: Color(0xFFFF6E6E),
        warning: Color(0xFFE5B567),
        muted: Color(0xFF9295A1),
        text: Color(0xFFE7E8ED),
        textSecondary: Color(0xFFB6C0B9),
        categoryColors: [
          Color(0xFF9290F5),
          Color(0xFF79A9E8),
          Color(0xFFB49AE8),
          Color(0xFF737987),
        ],
      ),
    ),
    RebootThemeDefinition(
      id: AppThemeId.light,
      name: 'REBOOT Light',
      palette: RebootPalette(
        brightness: Brightness.light,
        background: Color(0xFFF5F6F8),
        surface: Color(0xFFFFFFFF),
        surfaceRaised: Color(0xFFEDEFF3),
        border: Color(0xFFD9DCE3),
        accent: Color(0xFF5A57D6),
        accentSecondary: Color(0xFF2F6FBF),
        onAccent: Colors.white,
        success: Color(0xFF3D7A4D),
        danger: Color(0xFFC62828),
        warning: Color(0xFF9A6200),
        muted: Color(0xFF5F6370),
        text: Color(0xFF17181C),
        textSecondary: Color(0xFF3F4650),
        categoryColors: [
          Color(0xFF5A57D6),
          Color(0xFF2F6FBF),
          Color(0xFF8A5CC9),
          Color(0xFF6B7180),
        ],
      ),
    ),
    RebootThemeDefinition(
      id: AppThemeId.violet,
      name: 'Violet',
      palette: RebootPalette(
        brightness: Brightness.dark,
        background: Color(0xFF130F1C),
        surface: Color(0xFF1D1729),
        surfaceRaised: Color(0xFF272035),
        border: Color(0xFF3A3049),
        accent: Color(0xFFB794F6),
        accentSecondary: Color(0xFFE48FD0),
        onAccent: Color(0xFF1A1024),
        success: Color(0xFF9CCFA8),
        danger: Color(0xFFFF7A8A),
        warning: Color(0xFFE8C07A),
        muted: Color(0xFFA197B3),
        text: Color(0xFFEDE8F5),
        textSecondary: Color(0xFFC9BEDA),
        categoryColors: [
          Color(0xFFB794F6),
          Color(0xFFE48FD0),
          Color(0xFF8C9BF2),
          Color(0xFF7D7390),
        ],
      ),
    ),
    RebootThemeDefinition(
      id: AppThemeId.midnightBlue,
      name: 'Midnight Blue',
      palette: RebootPalette(
        brightness: Brightness.dark,
        background: Color(0xFF0B1220),
        surface: Color(0xFF121B2E),
        surfaceRaised: Color(0xFF1A2540),
        border: Color(0xFF283654),
        accent: Color(0xFF6FA8FF),
        accentSecondary: Color(0xFF5ED0E0),
        onAccent: Color(0xFF07101F),
        success: Color(0xFF7FC8A0),
        danger: Color(0xFFFF7878),
        warning: Color(0xFFE6BD6E),
        muted: Color(0xFF8D9AB3),
        text: Color(0xFFE5ECF7),
        textSecondary: Color(0xFFB7C4DA),
        categoryColors: [
          Color(0xFF6FA8FF),
          Color(0xFF5ED0E0),
          Color(0xFF9D8CF2),
          Color(0xFF6E7A92),
        ],
      ),
    ),
    RebootThemeDefinition(
      id: AppThemeId.emerald,
      name: 'Emerald',
      palette: RebootPalette(
        brightness: Brightness.dark,
        background: Color(0xFF0D1512),
        surface: Color(0xFF141F1B),
        surfaceRaised: Color(0xFF1C2A25),
        border: Color(0xFF2A3C35),
        accent: Color(0xFF5FD1A0),
        accentSecondary: Color(0xFF8FD3E8),
        onAccent: Color(0xFF06140E),
        success: Color(0xFF5FD1A0),
        danger: Color(0xFFFF7B7B),
        warning: Color(0xFFE3C46F),
        muted: Color(0xFF8FA39A),
        text: Color(0xFFE4F1EB),
        textSecondary: Color(0xFFB9CFC5),
        categoryColors: [
          Color(0xFF5FD1A0),
          Color(0xFF8FD3E8),
          Color(0xFFC3D97A),
          Color(0xFF718479),
        ],
      ),
    ),
  ];

  static RebootThemeDefinition byId(AppThemeId id) =>
      all.firstWhere((theme) => theme.id == id);

  /// Unknown or missing names fall back to REBOOT Dark.
  static AppThemeId parse(Object? name) {
    for (final id in AppThemeId.values) {
      if (id.name == name) return id;
    }
    return fallback;
  }

  static final _cache = <AppThemeId, ThemeData>{};

  static ThemeData build(AppThemeId id) =>
      _cache.putIfAbsent(id, () => _build(byId(id).palette));

  static ThemeData _build(RebootPalette p) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      fontFamily: 'SF Pro Display',
    );
    return base.copyWith(
      scaffoldBackgroundColor: p.background,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: p.accent,
            brightness: p.brightness,
          ).copyWith(
            primary: p.accent,
            onPrimary: p.onAccent,
            secondary: p.accentSecondary,
            surface: p.surface,
            onSurface: p.text,
            error: p.danger,
            outline: p.border,
          ),
      textTheme: _withTabularFigures(
        _textTheme.apply(bodyColor: p.text, displayColor: p.text),
      ),
      dividerColor: p.border,
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: p.border),
        ),
      ),
      dialogTheme: DialogThemeData(backgroundColor: p.surfaceRaised),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceRaised,
        contentTextStyle: TextStyle(color: p.text),
      ),
      extensions: [p],
    );
  }

  /// Every digit in the app uses tabular figures so values line up in
  /// columns and do not jitter when they change.
  static TextTheme _withTabularFigures(TextTheme theme) {
    TextStyle? tab(TextStyle? style) =>
        style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return theme.copyWith(
      displayLarge: tab(theme.displayLarge),
      displayMedium: tab(theme.displayMedium),
      displaySmall: tab(theme.displaySmall),
      headlineLarge: tab(theme.headlineLarge),
      headlineMedium: tab(theme.headlineMedium),
      headlineSmall: tab(theme.headlineSmall),
      titleLarge: tab(theme.titleLarge),
      titleMedium: tab(theme.titleMedium),
      titleSmall: tab(theme.titleSmall),
      bodyLarge: tab(theme.bodyLarge),
      bodyMedium: tab(theme.bodyMedium),
      bodySmall: tab(theme.bodySmall),
      labelLarge: tab(theme.labelLarge),
      labelMedium: tab(theme.labelMedium),
      labelSmall: tab(theme.labelSmall),
    );
  }

  static const _textTheme = TextTheme(
    headlineLarge: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.3,
    ),
    headlineMedium: TextStyle(
      fontSize: 25,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.7,
    ),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 15, height: 1.5),
    bodyMedium: TextStyle(fontSize: 13, height: 1.45),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
    ),
  );
}

extension RebootPaletteContext on BuildContext {
  RebootPalette get palette =>
      Theme.of(this).extension<RebootPalette>() ??
      RebootThemes.byId(RebootThemes.fallback).palette;
}
