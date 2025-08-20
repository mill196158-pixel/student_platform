import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppDecoration {
  final BoxDecoration decoration;
  AppDecoration({required this.decoration});

  factory AppDecoration.containerOnlyShadowTop(BuildContext context) {
    if (Theme.of(context).brightness == Brightness.dark) {
      return AppDecoration(
        decoration: BoxDecoration(
          color: colorPrimaryBlack,
          boxShadow: [
            BoxShadow(
              color: colorBlack.withOpacity(.65),
              offset: const Offset(-2, -2),
              blurRadius: 10,
            ),
          ],
        ),
      );
    } else {
      return AppDecoration(
        decoration: BoxDecoration(
          color: mC,
          boxShadow: [
            BoxShadow(
              color: mCL,
              offset: const Offset(-2, -2),
              blurRadius: 10,
            ),
          ],
        ),
      );
    }
  }
}
