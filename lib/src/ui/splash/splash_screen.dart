import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/src/core/session.dart';


class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Небольшая пауза для анимации
    await Future.delayed(const Duration(milliseconds: 600));
    await AppSession.loadFromServer();

    final prefs = await SharedPreferences.getInstance();

    final loggedIn = prefs.getBool('loggedIn') ?? false;
    final userJson = prefs.getString('user');
    final hasUser = userJson != null && jsonDecode(userJson) is Map;

    if (!mounted) return;
    if (loggedIn && hasUser) {
      context.go('/home');
    } else {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Lottie.asset('assets/lottie/cat_sleeping.json', height: 200),
            const SizedBox(height: 16),
            Text('Загружаем…', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}
