import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:get_storage/get_storage.dart'; // Временно отключено

enum ThemeOptions { light, dark }

class ThemeService extends ChangeNotifier {
  static ThemeOptions themeOptions = ThemeOptions.light;
  static ThemeMode currentTheme = ThemeMode.light;

  static final systemBrightness = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  );

  // final _getStorage = GetStorage(); // Временно отключено
  final storageKey = 'isDarkMode';

  switchStatusColor() {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: Platform.isIOS
          ? (isSavedDarkMode() ? Brightness.dark : Brightness.light)
          : (isSavedDarkMode() ? Brightness.light : Brightness.dark),
      statusBarIconBrightness: Platform.isIOS
          ? (isSavedDarkMode() ? Brightness.dark : Brightness.light)
          : (isSavedDarkMode() ? Brightness.light : Brightness.dark),
    ));
  }

  ThemeMode getThemeMode() {
    switchStatusColor();
    return isSavedDarkMode() ? ThemeMode.dark : ThemeMode.light;
  }

  bool isSavedDarkMode() {
    // return _getStorage.read(storageKey) ?? false; // Временно отключено
    return false; // По умолчанию светлая тема
  }

  void saveThemeMode(bool isDarkMode) async {
    // _getStorage.write(storageKey, isDarkMode); // Временно отключено
    // Временно не сохраняем настройки темы
  }

  void changeThemeMode() {
    saveThemeMode(!isSavedDarkMode());
    switchStatusColor();
    notifyListeners();
  }
}

ThemeService themeService = ThemeService();
