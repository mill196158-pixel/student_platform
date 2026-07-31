import 'package:flutter/material.dart';

/// Shared root navigator key (GoRouter + push deep links).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

BuildContext? get rootNavigatorContext => rootNavigatorKey.currentContext;
