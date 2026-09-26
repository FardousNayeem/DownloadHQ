import 'package:flutter/material.dart';

/// Design tokens. One accent (lime), zinc neutrals, Geist.
/// Shape rule: surfaces 16, inputs 12, buttons and chips full pill.
abstract final class Tokens {
  static const radiusSurface = 16.0;
  static const radiusInput = 12.0;
  static const gutter = 16.0;

  static const _limeDark = Color(0xFFC8F04A);
  static const _limeLight = Color(0xFF4A7A0C);
}

class _Palette {
  const _Palette({
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.line,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.danger,
  });

  final Color bg, surface, surfaceHi, line, text, muted, accent, onAccent, danger;
}

const _dark = _Palette(
  bg: Color(0xFF0E0E10),
  surface: Color(0xFF17171A),
  surfaceHi: Color(0xFF212125),
  line: Color(0xFF2A2A2F),
  text: Color(0xFFEDEDEF),
  muted: Color(0xFF9A9AA3),
  accent: Tokens._limeDark,
  onAccent: Color(0xFF14180A),
  danger: Color(0xFFFF7A6B),
);

const _light = _Palette(
  bg: Color(0xFFF6F6F7),
  surface: Color(0xFFFFFFFF),
  surfaceHi: Color(0xFFEDEDF0),
  line: Color(0xFFE0E0E4),
  text: Color(0xFF16161A),
  muted: Color(0xFF5E5E68),
  accent: Tokens._limeLight,
  onAccent: Color(0xFFF7FBEF),
  danger: Color(0xFFC0392B),
);

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? _dark : _light;
  final scheme = ColorScheme(
    brightness: b,
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    error: c.danger,
    onError: c.bg,
    surface: c.bg,
    onSurface: c.text,
    onSurfaceVariant: c.muted,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceHi,
    surfaceContainerHighest: c.surfaceHi,
    outline: c.line,
    outlineVariant: c.line,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Geist');
  final t = base.textTheme;
  const pill = StadiumBorder();
  return base.copyWith(
    scaffoldBackgroundColor: c.bg,
    textTheme: t.copyWith(
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.8),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.4),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.2),
      bodySmall: t.bodySmall?.copyWith(color: c.muted),
      labelSmall: t.labelSmall?.copyWith(color: c.muted, letterSpacing: 0.2),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      // Explicit size: ThemeData.textTheme has no sizes until localized, and
      // AppBar uses this style as is.
      titleTextStyle: TextStyle(
        fontFamily: 'Geist',
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: c.text,
        letterSpacing: -0.4,
      ),
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontFamily: 'Geist', fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: pill,
        side: BorderSide(color: c.line),
        foregroundColor: c.text,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: pill)),
    chipTheme: base.chipTheme.copyWith(
      shape: pill,
      side: BorderSide(color: c.line),
      backgroundColor: c.surface,
      selectedColor: c.accent.withValues(alpha: 0.18),
      labelStyle: TextStyle(fontFamily: 'Geist', color: c.text, fontSize: 13),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusInput),
        borderSide: BorderSide(color: c.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusInput),
        borderSide: BorderSide(color: c.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusInput),
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
      hintStyle: TextStyle(color: c.muted),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.radiusSurface)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.radiusSurface)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.surfaceHi,
      contentTextStyle: TextStyle(fontFamily: 'Geist', color: c.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.radiusInput)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.accent.withValues(alpha: 0.18),
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontFamily: 'Geist', fontSize: 12, color: c.text)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.bg,
      indicatorColor: c.accent.withValues(alpha: 0.18),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.line),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: c.muted, width: 1.5),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: Tokens.gutter)),
  );
}
