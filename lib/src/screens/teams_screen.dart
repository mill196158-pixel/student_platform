import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class TeamsScreen extends StatelessWidget {
  const TeamsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Команды"),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Lottie.asset(
              'assets/lottie/cat_sleeping.json', // заменил на рабочую кошку из календаря
              width: 180,
              height: 180,
              repeat: true,
            ),
            const SizedBox(height: 16),
            const Text(
              "Здесь будут ваши команды",
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
