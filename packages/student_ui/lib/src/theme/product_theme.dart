import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared visual contract for the student workspace and editorial console.
/// Data, permissions and routing deliberately stay outside this package.
abstract final class ProductTheme {
  static const blue = Color(0xFF1DA1F2);
  static const violet = Color(0xFF7C63D8);
  static const ink = Color(0xFF202737);
  static const muted = Color(0xFF606B7E);
  static const canvas = Color(0xFFF5F7FB);
  static const line = Color(0xFFDCE2EC);
  static const selectionMenuRadius = BorderRadius.all(Radius.circular(16));
  static const selectionMenuElevation = 4;

  static ThemeData build(
      {Brightness brightness = Brightness.light, Color accent = violet}) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
            .copyWith(
      primary: dark ? const Color(0xFFB9ABF4) : const Color(0xFF6550B4),
      secondary: blue,
      surface: dark ? const Color(0xFF202633) : Colors.white,
      onSurface: dark ? const Color(0xFFEDF0F7) : ink,
      onSurfaceVariant: dark ? const Color(0xFFB5BECE) : muted,
      outlineVariant: dark ? const Color(0xFF3C4657) : line,
      error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
    );
    final base = ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        fontFamily: 'WorkspaceSans',
        package: 'student_ui');
    final rawType = base.textTheme
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
        .copyWith(
          headlineLarge: TextStyle(
              fontSize: 32,
              height: 1.18,
              fontWeight: FontWeight.w700,
              letterSpacing: -.8,
              color: scheme.onSurface),
          headlineMedium: TextStyle(
              fontSize: 28,
              height: 1.22,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
              color: scheme.onSurface),
          headlineSmall: TextStyle(
              fontSize: 24,
              height: 1.25,
              fontWeight: FontWeight.w700,
              letterSpacing: -.4,
              color: scheme.onSurface),
          titleLarge: TextStyle(
              fontSize: 20,
              height: 1.3,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface),
          titleMedium: TextStyle(
              fontSize: 16,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface),
          bodyLarge:
              TextStyle(fontSize: 16, height: 1.5, color: scheme.onSurface),
          bodyMedium:
              TextStyle(fontSize: 14, height: 1.45, color: scheme.onSurface),
          bodySmall: TextStyle(
              fontSize: 12, height: 1.45, color: scheme.onSurfaceVariant),
        );
    final type =
        rawType.apply(fontFamily: base.textTheme.bodyMedium!.fontFamily);
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    final outline = OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.outlineVariant));
    return base.copyWith(
      textTheme: type,
      primaryColor: accent,
      scaffoldBackgroundColor: dark ? const Color(0xFF171D28) : canvas,
      canvasColor: scheme.surface,
      buttonTheme: base.buttonTheme.copyWith(alignedDropdown: true),
      dividerColor: scheme.outlineVariant,
      focusColor: scheme.primary.withValues(alpha: .16),
      hoverColor: scheme.primary.withValues(alpha: .05),
      appBarTheme: AppBarTheme(
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle:
              dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
          centerTitle: false,
          titleTextStyle: type.titleLarge),
      cardTheme: CardThemeData(
          color: scheme.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape:
              shape.copyWith(side: BorderSide(color: scheme.outlineVariant))),
      inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          border: outline,
          enabledBorder: outline,
          focusedBorder: outline.copyWith(
              borderSide: BorderSide(color: scheme.primary, width: 2)),
          errorBorder:
              outline.copyWith(borderSide: BorderSide(color: scheme.error)),
          focusedErrorBorder: outline.copyWith(
              borderSide: BorderSide(color: scheme.error, width: 2)),
          hintStyle: TextStyle(color: scheme.onSurfaceVariant),
          errorMaxLines: 3),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: shape)),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
              elevation: 0, minimumSize: const Size(48, 48), shape: shape)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              shape: shape,
              side: BorderSide(color: scheme.outlineVariant))),
      textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
              minimumSize: const Size(48, 48), shape: shape)),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
      dialogTheme: DialogThemeData(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          titleTextStyle: type.titleLarge,
          contentTextStyle: type.bodyMedium),
      bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          showDragHandle: false,
          modalBarrierColor: Colors.black54,
          constraints: const BoxConstraints(maxWidth: 720),
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)))),
      popupMenuTheme: PopupMenuThemeData(
          color: scheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: selectionMenuElevation.toDouble(),
          shadowColor: scheme.shadow.withValues(alpha: .24),
          menuPadding: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
              borderRadius: selectionMenuRadius,
              side: BorderSide(color: scheme.outlineVariant)),
          textStyle: type.bodyMedium),
      menuTheme: MenuThemeData(
          style: MenuStyle(
              backgroundColor: WidgetStatePropertyAll(scheme.surface),
              shape: WidgetStatePropertyAll(shape),
              elevation: const WidgetStatePropertyAll(4))),
      snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: dark ? const Color(0xFFE4E9F3) : ink,
          contentTextStyle:
              TextStyle(color: dark ? ink : Colors.white, height: 1.4),
          shape: shape,
          insetPadding: const EdgeInsets.all(16)),
      tooltipTheme: TooltipThemeData(
          triggerMode: TooltipTriggerMode.manual,
          waitDuration: const Duration(milliseconds: 500),
          decoration:
              BoxDecoration(color: ink, borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(color: Colors.white, fontSize: 12)),
      dataTableTheme: DataTableThemeData(
          headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
          headingTextStyle:
              type.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          dataTextStyle: type.bodyMedium,
          headingRowHeight: 48,
          dataRowMinHeight: 56,
          dataRowMaxHeight: 96,
          columnSpacing: 28,
          horizontalMargin: 20,
          dividerThickness: 1),
      tabBarTheme: TabBarThemeData(
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurfaceVariant,
          labelStyle: type.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: scheme.outlineVariant),
      listTileTheme: ListTileThemeData(
          iconColor: scheme.onSurfaceVariant,
          textColor: scheme.onSurface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          shape: shape),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, thickness: 1, space: 1),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: scheme.primary, linearMinHeight: 3),
      navigationRailTheme: NavigationRailThemeData(
          backgroundColor: scheme.surface,
          indicatorColor: scheme.primaryContainer,
          selectedIconTheme: IconThemeData(color: scheme.primary),
          selectedLabelTextStyle: type.labelLarge
              ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
          unselectedLabelTextStyle:
              type.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
    );
  }
}
