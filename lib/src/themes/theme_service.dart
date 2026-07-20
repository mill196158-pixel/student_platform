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

  /// Light app chrome → dark status icons; dark chrome → light icons.
  /// (Previously iOS light mode set [statusBarIconBrightness.light] = white icons.)
  static SystemUiOverlayStyle overlayFor({required bool darkMode}) {
    final darkIcons = !darkMode;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      // iOS: brightness of the *background* behind status icons.
      statusBarBrightness: darkIcons ? Brightness.light : Brightness.dark,
      statusBarIconBrightness: darkIcons ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          darkIcons ? Brightness.dark : Brightness.light,
    );
  }

  switchStatusColor() {
    SystemChrome.setSystemUIOverlayStyle(
      overlayFor(darkMode: isSavedDarkMode()),
    );
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
