import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Расписание занятий')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Lottie.asset(
              'assets/lottie/cat_sleeping.json',
              width: 180,
              height: 180,
              repeat: true,
            ),
            const SizedBox(height: 12),
            const Text(
              'Здесь пока пусто',
              style: TextStyle(fontSize: 14, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
