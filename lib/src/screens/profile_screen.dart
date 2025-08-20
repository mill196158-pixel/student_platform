import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _hasProfile = false; // демо: профиль не заполнен

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
        centerTitle: true,
      ),
      body: _hasProfile ? _buildProfileView() : _buildEmptyState(),
    );
  }

  Widget _buildProfileView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const CircleAvatar(
          radius: 50,
          backgroundImage: AssetImage('assets/images/avatar_placeholder.png'),
        ),
        const SizedBox(height: 16),
        const Text(
          'Иван Иванов',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Группа: ИС-21',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: () {
            setState(() {
              _hasProfile = false; // здесь можно менять на true при загрузке данных
            });
          },
          icon: const Icon(Icons.edit),
          label: const Text('Редактировать профиль'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
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
              'assets/lottie/cat_sleeping.json', // кошка
              width: 200,
              height: 200,
              repeat: true,
            ),
            const SizedBox(height: 16),
            const Text(
              'Профиль пока не заполнен',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
