import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';

/// Обёртка, которая ТОЛЬКО переключает экраны логина/регистрации.
/// Никаких запросов к БД здесь нет — весь красивый UI в LoginScreen как у тебя.
class AuthenticateScreen extends StatefulWidget {
  const AuthenticateScreen({super.key});

  @override
  State<AuthenticateScreen> createState() => _AuthenticateScreenState();
}

class _AuthenticateScreenState extends State<AuthenticateScreen> {
  bool _showLogin = true;

  void _toggle() {
    setState(() => _showLogin = !_showLogin);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _showLogin
          ? LoginScreen(key: const ValueKey('login'), toggleView: _toggle)
          : RegisterScreen(key: const ValueKey('register'), toggleView: _toggle),
    );
  }
}
