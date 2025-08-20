import 'package:flutter/material.dart';

/// ==== Цвета (взяты из Cloudmate стиля) ====
const _colorBlack = Color(0xFF121212);
const _colorPrimaryBlack = Color(0xFF14171A);
const _colorPrimary = Color(0xFF1DA1F2);

final Color _mC = Colors.grey.shade100; // background светлый
final Color _mCL = Colors.white;        // surface
final Color _mCM = Colors.grey.shade200;
final Color _mCH = Colors.grey.shade400;

class CApp {
  final Color primary;
  final Color background;
  final Color accent;
  final Color disabled;
  final Color error;
  final Color divider;
  final Color button;
  final Color text1;
  final Color text2;

  const CApp({
    required this.primary,
    required this.background,
    required this.accent,
    required this.disabled,
    required this.error,
    required this.divider,
    required this.button,
    required this.text1,
    required this.text2,
  });

  factory CApp.light() => CApp(
    primary: _colorPrimary,
    background: _mC,
    accent: const Color(0xFF17C063),
    disabled: Colors.black12,
    error: const Color(0xFFFF7466),
    divider: Colors.black26,
    button: const Color(0xFF657786),
    text1: _colorBlack,
    text2: _colorPrimaryBlack,
  );

  factory CApp.dark() => CApp(
    primary: _colorPrimary,
    background: const Color(0xFF14171A),
    accent: const Color(0xFF17C063),
    disabled: Colors.white12,
    error: const Color(0xFFFF5544),
    divider: Colors.white24,
    button: Colors.white,
    text1: _mCL,
    text2: _mCL,
  );
}

class AppTheme {
  static ThemeData light =
  _themeFrom(CApp.light(), brightness: Brightness.light);
  static ThemeData dark =
  _themeFrom(CApp.dark(), brightness: Brightness.dark);

  static ThemeData _themeFrom(CApp c, {required Brightness brightness}) {
    const uiFont = 'Lato'; // основной шрифт UI

    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.primary,
      onPrimary: Colors.white,
      secondary: c.accent,
      onSecondary: Colors.white,
      error: c.error,
      onError: Colors.white,
      surface: _mCL,
      onSurface: c.text1,
      background: c.background,
      onBackground: c.text1,
      outline: c.divider,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.background,
      appBarTheme: AppBarTheme(
        backgroundColor: _mCL,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        foregroundColor: c.text1,
        titleTextStyle: TextStyle(
          fontFamily: uiFont,
          fontWeight: FontWeight.w700,
          fontSize: 18,
          color: c.text1,
        ),
      ),
      textTheme: TextTheme(
        displaySmall: TextStyle(
            fontFamily: uiFont,
            fontWeight: FontWeight.w700,
            fontSize: 28,
            color: c.text1),
        titleLarge: TextStyle(
            fontFamily: uiFont,
            fontWeight: FontWeight.w700,
            fontSize: 22,
            color: c.text1),
        titleMedium: TextStyle(
            fontFamily: uiFont,
            fontWeight: FontWeight.w600,
            fontSize: 18,
            color: c.text1),
        bodyLarge: TextStyle(
            fontFamily: uiFont,
            fontWeight: FontWeight.w500,
            fontSize: 16,
            color: c.text2),
        bodyMedium: TextStyle(
            fontFamily: uiFont,
            fontWeight: FontWeight.w400,
            fontSize: 14,
            color: c.text2),
        labelLarge: TextStyle(
            fontFamily: uiFont,
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: c.text1),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _mCL,
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: TextStyle(color: _mCH),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _mCH),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _mCH),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.primary, width: 2),
        ),
      ),
      cardTheme: CardThemeData(
        color: _mCL,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      dividerColor: c.divider,
    );
  }
}
