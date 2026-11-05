import 'package:flutter/material.dart';
import 'student_bottom_nav.dart';

/// Stable Row/Expanded ancestry keeps tab state intact across breakpoints.
class StudentWorkspaceFrame extends StatelessWidget {
  const StudentWorkspaceFrame(
      {super.key,
      required this.index,
      required this.onSelected,
      required this.child,
      this.maxContentWidth = 1200});
  final int index;
  final ValueChanged<int> onSelected;
  final Widget child;
  final double maxContentWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
        final wide = size.maxWidth >= 760;
        final extended = size.maxWidth >= 1180;
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          body: Row(children: [
            SizedBox(
                width: wide ? (extended ? 224 : 96) : 0,
                child: wide
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                            color: scheme.surface,
                            border: Border(
                                right:
                                    BorderSide(color: scheme.outlineVariant))),
                        child: SafeArea(
                            child: Column(children: [
                          if (size.maxHeight >= 600)
                            Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 28, horizontal: 12),
                                child: extended
                                    ? Row(children: [
                                        Icon(Icons.school_outlined,
                                            color: scheme.primary),
                                        const SizedBox(width: 12),
                                        const Text('Студент',
                                            style: TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w700))
                                      ])
                                    : Icon(Icons.school_outlined,
                                        color: scheme.primary)),
                          Expanded(
                              child: NavigationRail(
                                  extended: extended,
                                  minWidth: 94,
                                  minExtendedWidth: 222,
                                  selectedIndex: index,
                                  onDestinationSelected: onSelected,
                                  labelType: extended || size.maxHeight < 600
                                      ? NavigationRailLabelType.none
                                      : NavigationRailLabelType.all,
                                  destinations: [
                                for (final item in studentBottomNavItems)
                                  NavigationRailDestination(
                                      icon: Icon(item.icon),
                                      label: Text(item.label))
                              ])),
                        ])))
                    : const SizedBox.shrink()),
            Expanded(
                child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxContentWidth),
                        child: child))),
          ]),
          bottomNavigationBar: wide
              ? null
              : StudentBottomNav(
                  currentIndex: index,
                  onTap: onSelected,
                  items: studentBottomNavItems),
        );
      });
}
