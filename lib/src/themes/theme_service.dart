import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ValueNotifier<ThemeMode> {
  ThemeService() : super(ThemeMode.system);

  static const _key = 'themeMode';
  static const _legacyKey = 'isDarkMode';
  SharedPreferences? _preferences;

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _preferences = prefs;
      final saved = prefs.getString(_key);
      final legacy = prefs.getBool(_legacyKey);
      value = ThemeMode.values.asNameMap()[saved] ??
          (legacy == null
              ? ThemeMode.system
              : legacy
                  ? ThemeMode.dark
                  : ThemeMode.light);
    } catch (error) {
      debugPrint('[theme] Could not read preference: ${error.runtimeType}');
    }
  }

  Future<void> select(ThemeMode mode) async {
    if (mode == value) return;
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final saved = await prefs.setString(_key, mode.name);
    if (!saved) throw StateError('Theme preference could not be saved');
    value = mode;
  }

  static SystemUiOverlayStyle overlayFor({required bool darkMode}) {
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: darkMode ? Brightness.dark : Brightness.light,
      statusBarIconBrightness: darkMode ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          darkMode ? Brightness.light : Brightness.dark,
    );
  }
}

final themeService = ThemeService();
