import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

/// Entry surfaces follow the current app theme.
ThemeData guestPresentationTheme(ThemeData base) =>
    ProductTheme.build(brightness: base.brightness);
