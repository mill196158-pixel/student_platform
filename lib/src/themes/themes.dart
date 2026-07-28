import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme({
    required this.mode,
    required this.data,
    required this.appColors,
  });

  factory AppTheme.light() {
    final mode = ThemeMode.light;
    final appColors = AppColors.light();
    final base = ThemeData.light(useMaterial3: true);
    final themeData = base.copyWith(
      primaryColor: appColors.primary,
      scaffoldBackgroundColor: appColors.background,
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: appColors.background,
        selectedItemColor: colorPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: appColors.background,
        foregroundColor: appColors.contentText1,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: appColors.header,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: appColors.contentText1),
      ),
      // Keep full Material typography; only recolor. A sparse TextTheme()
      // left title/headline styles without colors → near-invisible titles.
      textTheme: base.textTheme.apply(
        bodyColor: appColors.contentText1,
        displayColor: appColors.header,
      ),
      dividerColor: appColors.divider,
    );
    return AppTheme(mode: mode, data: themeData, appColors: appColors);
  }

  factory AppTheme.dark() {
    final mode = ThemeMode.dark;
    final appColors = AppColors.dark();
    final base = ThemeData.dark(useMaterial3: true);
    final themeData = base.copyWith(
      primaryColor: appColors.primary,
      scaffoldBackgroundColor: appColors.background,
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: appColors.background,
        selectedItemColor: colorPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: appColors.background,
        foregroundColor: appColors.contentText1,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: appColors.header,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: appColors.contentText1),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: appColors.contentText1,
        displayColor: appColors.header,
      ),
      dividerColor: appColors.divider,
    );
    return AppTheme(mode: mode, data: themeData, appColors: appColors);
  }

  final ThemeMode mode;
  final ThemeData data;
  final AppColors appColors;
}
