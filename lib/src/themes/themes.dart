import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme({required this.mode, required this.data, required this.appColors});
  factory AppTheme.light() => AppTheme(
      mode: ThemeMode.light,
      data: ProductTheme.build(),
      appColors: AppColors.light());
  factory AppTheme.dark() => AppTheme(
      mode: ThemeMode.dark,
      data: ProductTheme.build(brightness: Brightness.dark),
      appColors: AppColors.dark());
  final ThemeMode mode;
  final ThemeData data;
  final AppColors appColors;
}
