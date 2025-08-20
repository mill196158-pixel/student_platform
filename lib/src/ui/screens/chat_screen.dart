import 'package:flutter/material.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Чат по предмету')),
      body: const Center(
        child: Text(
          'Чаты пока в демо-режиме',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
