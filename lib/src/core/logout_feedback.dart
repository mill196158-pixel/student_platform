import 'package:flutter/material.dart';

import 'logout_cleanup.dart';

/// The root messenger survives removal of the initiating page during logout.
void showLogoutFeedback(
    GlobalKey<ScaffoldMessengerState> key, LogoutCleanupResult result) {
  final message = switch (result) {
    LogoutCleanupResult.blockedBeforeSignOut =>
      'Не удалось завершить выход. Попробуйте ещё раз.',
    LogoutCleanupResult.signOutUnconfirmed =>
      'Не удалось подтвердить выход. Проверьте соединение.',
    LogoutCleanupResult.signedOutCleanupIncomplete =>
      'Вы вышли из аккаунта, но часть локальных данных не удалось очистить.',
    LogoutCleanupResult.signedOut => null,
    LogoutCleanupResult.ownerChanged => null,
  };
  if (message == null) return;
  key.currentState?.showSnackBar(SnackBar(content: Text(message)));
}
