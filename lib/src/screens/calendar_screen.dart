import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Временно пустой список событий
    final List<String> events = [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Календарь'),
        centerTitle: true,
      ),
      body: events.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: events.length,
              itemBuilder: (context, index) {
                return Card(
                  elevation: 1,
                  child: ListTile(
                    title: Text(events[index]),
                    subtitle: const Text('Детали события...'),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Lottie.asset(
            'assets/lottie/cat_sleeping.json',
            width: 150,
            height: 150,
            repeat: true,
          ),
          const SizedBox(height: 16),
          const Text(
            'Здесь пока пусто',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Добавьте события в календарь, чтобы оно появилось здесь.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
