import 'package:flutter/material.dart';
import '../widgets/empty_state_widget.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final List<String> news = [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Главная'),
        centerTitle: true,
      ),
      body: news.isEmpty
          ? const SingleChildScrollView(
              physics: NeverScrollableScrollPhysics(),
              child: SizedBox(
                height: 500, // фиктивная высота для центрирования
                child: Center(
                  child: EmptyStateWidget(
                    title: 'Здесь пока пусто',
                    subtitle: 'Новости появятся здесь.',
                  ),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: news.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(news[index]),
                );
              },
            ),
    );
  }
}
