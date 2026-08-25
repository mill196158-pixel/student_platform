import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

/// Presentation-only Student Platform phone chrome for Admin Web previews.
///
/// The frame deliberately owns only device presentation. Editor state, sample
/// data, repositories, and content remain the responsibility of [child].
class AdminStudentPhoneFrame extends StatelessWidget {
  const AdminStudentPhoneFrame({
    required this.child,
    this.showBottomNavigation = false,
    this.navigationIndex,
    this.onNavigationTap,
    super.key,
  }) : assert(
         showBottomNavigation
             ? navigationIndex != null &&
                   navigationIndex >= 0 &&
                   navigationIndex < studentBottomNavItems.length
             : navigationIndex == null,
         'navigationIndex must be a valid student navigation index exactly '
         'when showBottomNavigation is true.',
       ),
       assert(
         showBottomNavigation || onNavigationTap == null,
         'onNavigationTap requires showBottomNavigation.',
       );

  static const designWidth = 390.0;
  static const designHeight = 844.0;

  final Widget child;
  final bool showBottomNavigation;
  final int? navigationIndex;
  final ValueChanged<int>? onNavigationTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('admin-student-phone-frame'),
      decoration: const BoxDecoration(color: Color(0xFFE9EAF1)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? math.max(0.0, constraints.maxWidth)
                : designWidth;
            final availableHeight = constraints.maxHeight.isFinite
                ? math.max(0.0, constraints.maxHeight)
                : designHeight;
            final scale = math
                .min(
                  availableWidth / designWidth,
                  availableHeight / designHeight,
                )
                .clamp(0.0, 1.0);

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
                      color: const Color(0xFFF7F7FB),
                      borderRadius: BorderRadius.circular(42),
                      border: Border.all(
                        color: const Color(0xFF242536),
                        width: 8,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          blurRadius: 24,
                          color: Color(0x22000000),
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Theme(
                      data: studentPlatformLightTheme(),
                      child: MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          size: const Size(designWidth - 16, designHeight - 16),
                          padding: const EdgeInsets.only(top: 24),
                          viewPadding: const EdgeInsets.only(top: 24),
                          textScaler: TextScaler.noScaling,
                        ),
                        child: Stack(
                          children: [
                            Column(
                              children: [
                                Expanded(child: child),
                                if (showBottomNavigation)
                                  StudentBottomNav(
                                    currentIndex: navigationIndex!,
                                    items: studentBottomNavItems,
                                    onTap: onNavigationTap ?? (_) {},
                                  ),
                              ],
                            ),
                            const Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(child: _PhoneSystemBar()),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PhoneSystemBar extends StatelessWidget {
  const _PhoneSystemBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('admin-student-phone-system-bar'),
      height: 24,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: 108,
          height: 22,
          decoration: const BoxDecoration(
            color: Color(0xFF242536),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
          ),
        ),
      ),
    );
  }
}
