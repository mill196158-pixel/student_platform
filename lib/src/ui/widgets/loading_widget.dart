import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class LoadingWidget extends StatelessWidget {
  final String? message;
  const LoadingWidget({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Анимация кошки
          SizedBox(
            height: 150,
            child: Lottie.asset(
              'assets/lottie/cat_loading.json',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 16),
          // Сообщение
          Text(
            message ?? 'Загрузка...',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
