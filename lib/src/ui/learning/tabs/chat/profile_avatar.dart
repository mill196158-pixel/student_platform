import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// Ничего не знаем про твою модель профиля — читаем state динамически.
// Если ничего нет — будут инициалы.
class ProfileAvatar extends StatelessWidget {
  final String name;       // для инициалов
  final String? imageUrl;  // если уже есть готовый url — используем
  final double radius;

  const ProfileAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.radius = 14,
  });

  @override
  Widget build(BuildContext context) {
    String? url = imageUrl;

    // Осторожная попытка достать мою аватарку из Cubit.state (динамически).
    // Работает, даже если полей нет — просто останутся инициалы.
    if (url == null) {
      try {
        final cubit = context.read<dynamic>(); // не указываем тип
        final st = cubit.state;                // dynamic
        // Пробуем самые очевидные места:
        url = st?.profile?.avatarUrl ??
              st?.me?.avatarUrl ??
              st?.user?.avatarUrl;
      } catch (_) {}
    }

    Widget child;
    if (url is String && url.trim().isNotEmpty) {
      child = ClipOval(
        child: Image.network(url, width: radius * 2, height: radius * 2, fit: BoxFit.cover),
      );
    } else {
      final initials = _initials(name);
      child = CircleAvatar(
        radius: radius,
        child: Text(initials, style: const TextStyle(fontSize: 11)),
      );
    }
    return SizedBox(width: radius * 2, height: radius * 2, child: child);
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return 'U';
    final a = parts[0].isNotEmpty ? parts[0][0] : '';
    final b = parts.length > 1 && parts[1].isNotEmpty ? parts[1][0] : '';
    return (a + b).toUpperCase();
  }
}
