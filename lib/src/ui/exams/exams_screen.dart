import 'package:flutter/material.dart';

class ExamsScreen extends StatelessWidget {
  const ExamsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // сюда потом прикрутим реальные данные/таблицу
    return Scaffold(
      appBar: AppBar(title: const Text('Зачёты и экзамены')),
      body: const Center(
        child: Text('Тут будет список зачётов и экзаменов (демо)'),
      ),
    );
  }
}
