import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cloudmate/src/blocs/profile/profile_cubit.dart';
import 'package:cloudmate/src/models/demo_user.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _firstName;
  late TextEditingController _lastName;
  late TextEditingController _status;

  @override
  void initState() {
    super.initState();
    final user = profileCubit.state;
    _firstName = TextEditingController(text: user.firstName);
    _lastName  = TextEditingController(text: user.lastName);
    _status    = TextEditingController(text: user.status);
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _status.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState?.validate() ?? false) {
      context.read<ProfileCubit>().update(
        firstName: _firstName.text.trim(),
        lastName: _lastName.text.trim(),
        status: _status.text.trim(),
      );
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Профиль обновлён')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: profileCubit,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Редактировать профиль'),
          centerTitle: true,
          actions: [
            IconButton(onPressed: _save, icon: const Icon(Icons.check)),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                _field(label: 'Имя', controller: _firstName, validatorMsg: 'Введите имя'),
                _field(label: 'Фамилия', controller: _lastName, validatorMsg: 'Введите фамилию'),
                _field(label: 'Статус (интро)', controller: _status, maxLines: 3),
                const SizedBox(height: 24),
                Text(
                  'Подсказка: это офлайн демо. Данные сохраняются в памяти до перезапуска приложения.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? validatorMsg,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        validator: (v) {
          if ((validatorMsg != null) && (v == null || v.trim().isEmpty)) return validatorMsg;
          return null;
        },
      ),
    );
  }
}
