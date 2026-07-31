import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Phone chrome frame wrapping a preview child for all content editors.
class PhonePreviewFrame extends StatelessWidget {
  const PhonePreviewFrame({
    required this.child,
    this.showStatusBar = true,
    this.showHomeIndicator = true,
    this.designWidth = 390,
    this.designHeight = 844,
    super.key,
  });

  final Widget child;
  final bool showStatusBar;
  final bool showHomeIndicator;
  final double designWidth;
  final double designHeight;

  static const _bezelColor = Color(0xFF242536);
  static const _screenColor = Color(0xFFF7F7FB);
  static const _cardColor = Color(0xFFE9EAF1);

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _cardColor,
      clipBehavior: Clip.hardEdge,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = math.max(0.0, constraints.maxWidth - 24);
          final availableHeight = math.max(0.0, constraints.maxHeight - 24);
          final scale = math
              .min(availableWidth / designWidth, availableHeight / designHeight)
              .clamp(0.35, 1.0);

          return Center(
            child: SizedBox(
              width: designWidth * scale,
              height: designHeight * scale,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Container(
                  width: designWidth,
                  height: designHeight,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: _screenColor,
                    borderRadius: BorderRadius.circular(42),
                    border: Border.all(color: _bezelColor, width: 8),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 24,
                        color: Color(0x22000000),
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      size: Size(designWidth - 16, designHeight - 16),
                      padding: showStatusBar
                          ? const EdgeInsets.only(top: 24)
                          : EdgeInsets.zero,
                      viewPadding: showStatusBar
                          ? const EdgeInsets.only(top: 24)
                          : EdgeInsets.zero,
                      textScaler: TextScaler.noScaling,
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(child: child),
                        if (showStatusBar)
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(child: _PhoneStatusBar()),
                          ),
                        if (showHomeIndicator)
                          const Positioned(
                            left: 0,
                            right: 0,
                            bottom: 8,
                            child: IgnorePointer(child: _PhoneHomeIndicator()),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PhoneStatusBar extends StatelessWidget {
  const _PhoneStatusBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Container(
            width: 108,
            height: 22,
            decoration: const BoxDecoration(
              color: PhonePreviewFrame._bezelColor,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneHomeIndicator extends StatelessWidget {
  const _PhoneHomeIndicator();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 120,
        height: 4,
        decoration: BoxDecoration(
          color: PhonePreviewFrame._bezelColor.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}
