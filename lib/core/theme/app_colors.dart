// Purpose: the single source of truth for every colour in the app.
import 'package:material_ui/material_ui.dart';

/// Semantic palette for one brightness. Widgets read this instead of
/// `Theme.of(context).colorScheme`, so changing the brand stays in one file.
@immutable
class AppColorsData {
  const AppColorsData({
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.tertiary,
    required this.onTertiary,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceContainer,
    required this.surfaceHigh,
    required this.outline,
    required this.outlineVariant,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
  });

  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color tertiary;
  final Color onTertiary;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceContainer;
  final Color surfaceHigh;
  final Color outline;
  final Color outlineVariant;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;
}

abstract final class AppColors {
  /// Brand accent shared by both brightnesses.
  static const Color seed = Color(0xFF5EF2C2);
  static const Color mint = Color(0xFF62F5C8);
  static const Color violet = Color(0xFF9B8CFF);
  static const Color amber = Color(0xFFFFB86B);
  static const Color telegram = Color(0xFF2AABEE);
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);

  static const AppColorsData light = AppColorsData(
    primary: Color(0xFF007A63),
    onPrimary: white,
    secondary: Color(0xFF5B4BD6),
    onSecondary: white,
    tertiary: Color(0xFF9A5A00),
    onTertiary: white,
    surface: Color(0xFFF4F7F4),
    surfaceLow: white,
    surfaceContainer: Color(0xFFEDF2EE),
    surfaceHigh: Color(0xFFE3EAE5),
    outline: Color(0xFF8A9A90),
    outlineVariant: Color(0xFFD5DED8),
    onSurface: Color(0xFF111A14),
    onSurfaceVariant: Color(0xFF4B5B52),
    error: Color(0xFFB3261E),
    onError: white,
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
  );

  static const AppColorsData dark = AppColorsData(
    primary: mint,
    onPrimary: Color(0xFF03130E),
    secondary: violet,
    onSecondary: Color(0xFF100A2A),
    tertiary: amber,
    onTertiary: Color(0xFF2A1600),
    surface: Color(0xFF070B14),
    surfaceLow: Color(0xFF0D1422),
    surfaceContainer: Color(0xFF111A2B),
    surfaceHigh: Color(0xFF18233A),
    outline: Color(0xFF3A4A63),
    outlineVariant: Color(0xFF263247),
    onSurface: Color(0xFFE7F5EF),
    onSurfaceVariant: Color(0xFF9AAEBB),
    error: Color(0xFFFF7A7A),
    onError: Color(0xFF2A0505),
    errorContainer: Color(0xFF3A1518),
    onErrorContainer: Color(0xFFFFD4D4),
  );

  /// Static palette used by widgets. It is updated once per app build from
  /// the selected theme, so call sites never need `BuildContext`.
  static AppColorsData _palette = dark;

  static AppColorsData get palette => _palette;

  static void useBrightness(Brightness brightness) {
    _palette = brightness == Brightness.dark ? dark : light;
  }

  static Color get primary => _palette.primary;
  static Color get onPrimary => _palette.onPrimary;
  static Color get secondary => _palette.secondary;
  static Color get onSecondary => _palette.onSecondary;
  static Color get tertiary => _palette.tertiary;
  static Color get onTertiary => _palette.onTertiary;
  static Color get surface => _palette.surface;
  static Color get surfaceLow => _palette.surfaceLow;
  static Color get surfaceContainer => _palette.surfaceContainer;
  static Color get surfaceHigh => _palette.surfaceHigh;
  static Color get outline => _palette.outline;
  static Color get outlineVariant => _palette.outlineVariant;
  static Color get onSurface => _palette.onSurface;
  static Color get onSurfaceVariant => _palette.onSurfaceVariant;
  static Color get error => _palette.error;
  static Color get onError => _palette.onError;
  static Color get errorContainer => _palette.errorContainer;
  static Color get onErrorContainer => _palette.onErrorContainer;
}
