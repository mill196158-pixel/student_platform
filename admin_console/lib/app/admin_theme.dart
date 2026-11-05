import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

abstract final class AdminTheme {
  static ThemeData get light =>
      ProductTheme.build(accent: const Color(0xFF6656D9));
}
