import 'package:flutter/material.dart';

/// Shared root navigator key (GoRouter + push deep links).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

BuildContext? get rootNavigatorContext => rootNavigatorKey.currentContext;
