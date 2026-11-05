import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Branded indeterminate loading mark for screens, panels, and inline actions.
class ProductLoadingIndicator extends StatelessWidget {
  const ProductLoadingIndicator({
    super.key,
    this.color,
    this.size = 48,
    this.semanticsLabel = 'Загрузка',
  });

  /// Use when loading replaces the main content of a screen or panel.
  const ProductLoadingIndicator.page({
    super.key,
    this.color,
    this.semanticsLabel = 'Загрузка',
  }) : size = 120;

  final Color? color;
  final double size;
  final String semanticsLabel;

  static const _asset = 'assets/animations/cat_loader.json';
  static const _package = 'student_ui';

  /// Makes the composition available for the first frame of the launch screen.
  static Future<void> preload() async {
    try {
      await AssetLottie(_asset, package: _package).load();
    } catch (_) {
      // The indicator renders its fallback if the animation cannot be loaded.
    }
  }

  @override
  Widget build(BuildContext context) {
    final animate =
        !MediaQuery.disableAnimationsOf(context) && TickerMode.of(context);
    final theme = Theme.of(context);
    final needsLightArtwork = theme.brightness == Brightness.dark ||
        (color?.computeLuminance() ?? 0) > .75;
    final fallback = Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Icon(Icons.pets_rounded,
            size: size * .65, color: color ?? theme.colorScheme.primary),
      ),
    );
    return Semantics(
      label: semanticsLabel,
      child: Align(
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox.square(
          dimension: size,
          child: Lottie.asset(
            _asset,
            package: _package,
            fit: BoxFit.contain,
            animate: animate,
            repeat: animate,
            frameBuilder: (context, child, composition) {
              if (composition == null) return fallback;
              if (!needsLightArtwork) return child;
              return ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Color(0x55FFFFFF),
                  BlendMode.srcATop,
                ),
                child: child,
              );
            },
            errorBuilder: (context, error, stackTrace) => fallback,
          ),
        ),
      ),
    );
  }
}
