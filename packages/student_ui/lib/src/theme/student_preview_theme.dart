import 'package:flutter/material.dart';

ThemeData studentPlatformLightTheme() {
  const primary = Color(0xFF1DA1F2);
  const background = Color(0xFFF5F5F5);
  const textPrimary = Color(0xFF121212);
  const textSecondary = Color(0xFF14171A);

  return ThemeData.light().copyWith(
    primaryColor: primary,
    scaffoldBackgroundColor: background,
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: background,
      selectedItemColor: primary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      iconTheme: IconThemeData(color: textPrimary),
    ),
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: textPrimary),
      bodyLarge: TextStyle(color: textPrimary),
      bodyMedium: TextStyle(color: textSecondary),
    ),
    dividerColor: Colors.black26,
  );
}
