import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class ClassesScreen extends StatelessWidget {
  const ClassesScreen({super.key});

  final bool _hasClasses = false; // демо: нет занятий

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Занятия'),
        centerTitle: true,
      ),
      body: _hasClasses ? _buildClassesList() : _buildEmptyState(),
    );
  }

  Widget _buildClassesList() {
    final classes = [
      {'subject': 'Математика', 'location': 'Ауд. 203', 'time': '08:30'},
      {'subject': 'История', 'location': 'Ауд. 105', 'time': '10:20'},
      {'subject': 'Физика', 'location': 'Ауд. 307', 'time': '13:00'},
    ];

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: classes.length,
      itemBuilder: (context, index) {
        final c = classes[index];
        return Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            leading: const Icon(Icons.book, color: Colors.blue),
            title: Text(c['subject']!),
            subtitle: Text('${c['location']} • ${c['time']}'),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Lottie.asset(
              'assets/lottie/cat_sleeping.json', // рабочая кошка из календаря
              width: 200,
              height: 200,
              repeat: true,
            ),
            const SizedBox(height: 16),
            const Text(
              'Занятий пока нет',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
