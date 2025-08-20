import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _university = TextEditingController();
  final _group = TextEditingController();

  final List<String> _statuses = const [
    'Онлайн',
    'Занят 🚫',
    'На паре',
    'В библиотеке',
    'Готовлюсь к сессии 💪',
    'Отошёл',
  ];
  String _status = 'Онлайн';

  String? _avatarPath; // локальный превью
  String? _avatarUrl;  // url из БД

  bool _saving = false;
  Map<String, dynamic>? _user;

  final _sb = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('user');
    if (userJson != null) {
      _user = jsonDecode(userJson) as Map<String, dynamic>;
      _firstName.text  = (_user?['name'] ?? '') as String;
      _lastName.text   = (_user?['surname'] ?? '') as String;
      _university.text = (_user?['university'] ?? '') as String;
      _group.text      = (_user?['group_name'] ?? '') as String;
      final st = (_user?['status'] ?? '') as String;
      if (st.isNotEmpty) _status = st;
      _avatarUrl = (_user?['avatar_url'] as String?)?.trim();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _university.dispose();
    _group.dispose();
    super.dispose();
  }

  /// Загрузка в `<uid>/<fileName>.jpg`. Это критично для RLS.
  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null || _user == null) return;

    setState(() => _avatarPath = picked.path);

    try {
      final id = _user!['id'] as String; // auth.uid()
      final bytes = await File(picked.path).readAsBytes();
      final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final path = '$id/$fileName'; // <— ВАЖНО: папка пользователя

      await _sb.storage.from('avatars').uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(
          upsert: true,
          contentType: 'image/jpeg',
        ),
      );

      final publicUrl = _sb.storage.from('avatars').getPublicUrl(path);

      await _sb.from('users').update({'avatar_url': publicUrl}).eq('id', id);

      final prefs = await SharedPreferences.getInstance();
      final u = Map<String, dynamic>.from(_user!);
      u['avatar_url'] = publicUrl;
      _user = u;
      _avatarUrl = publicUrl;
      await prefs.setString('user', jsonEncode(u));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Аватар обновлён')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка загрузки аватара: $e')),
      );
    }
  }

  Future<void> _save() async {
    // сейчас поля только для чтения — по кнопке просто выходим
    if (!mounted) return;
    context.pop();
  }

  Future<void> _setStatus(String newStatus) async {
    if (_user == null) return;
    setState(() => _status = newStatus);
    try {
      final id = _user!['id'] as String;
      await _sb.from('users').update({'status': newStatus}).eq('id', id);

      final prefs = await SharedPreferences.getInstance();
      final u = Map<String, dynamic>.from(_user!);
      u['status'] = newStatus;
      _user = u;
      await prefs.setString('user', jsonEncode(u));
    } catch (_) {}
  }

  /// Красивая смена пароля: два поля, без BCrypt.
  Future<void> _changePasswordDialog() async {
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Смена пароля'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Новый пароль'),
            ),
            TextField(
              controller: confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Повторите пароль'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final a = newCtrl.text.trim();
              final b = confirmCtrl.text.trim();

              if (a.length < 6) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Минимум 6 символов')),
                  );
                }
                return;
              }
              if (a != b) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Пароли не совпадают')),
                  );
                }
                return;
              }

              try {
                await _sb.auth.updateUser(UserAttributes(password: a));
                if (mounted) {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Пароль изменён')),
                  );
                }
              } on AuthException catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.message)),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Ошибка: $e')),
                  );
                }
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    ImageProvider? avatarProvider;
    if (_avatarPath != null) {
      avatarProvider = FileImage(File(_avatarPath!));
    } else if (_avatarUrl != null && _avatarUrl!.isNotEmpty) {
      avatarProvider = CachedNetworkImageProvider(_avatarUrl!);
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => context.pop(),
        ),
        title: const Text('Редактировать профиль'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Готово'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // ==== AVATAR ====
            Center(
              child: Stack(
                children: [
                  Container(
                    width: 120,
                    height: 120,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFF8EC5FC), Color(0xFFE0C3FC)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Center(
                      child: CircleAvatar(
                        radius: 54,
                        backgroundColor: Colors.white,
                        backgroundImage: avatarProvider,
                        child: avatarProvider == null
                            ? const Icon(Icons.person, size: 44, color: Colors.black54)
                            : null,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: _pickAvatar,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(context).colorScheme.primary.withOpacity(.35),
                              blurRadius: 10,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.edit, color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ==== READ-ONLY FIELDS ====
            _LabeledField(label: 'Имя',         hint: 'Введите имя',         controller: _firstName,   readOnly: true),
            _Divider(),
            _LabeledField(label: 'Фамилия',     hint: 'Введите фамилию',     controller: _lastName,    readOnly: true),
            _Divider(),
            _LabeledField(label: 'Университет', hint: 'Например: СПбГАСУ',   controller: _university,  readOnly: true),
            _Divider(),
            _LabeledField(label: 'Группа/курс', hint: 'Например: 1-См(ВВ)-2',controller: _group,       readOnly: true),

            const SizedBox(height: 12),

            // ==== STATUS CHIPS ====
            Text('Статус',
                style: text.labelMedium?.copyWith(color: Colors.black54, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: -4,
              children: _statuses.map((s) {
                final selected = _status == s;
                return ChoiceChip(
                  label: Text(s),
                  selected: selected,
                  onSelected: (_) => _setStatus(s),
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                  selectedColor: Theme.of(context).colorScheme.primary,
                  backgroundColor: Colors.grey.shade200,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                );
              }).toList(),
            ),

            const SizedBox(height: 28),

            // ==== PASSWORD ====
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: const Text('Сменить пароль'),
              subtitle: const Text('Два поля: новый и повтор'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _changePasswordDialog,
            ),
          ],
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool readOnly;
  final int maxLines;
  final TextInputType? keyboardType;

  const _LabeledField({
    required this.label,
    required this.hint,
    required this.controller,
    this.readOnly = false,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: Colors.black54, fontWeight: FontWeight.w600);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        enableInteractiveSelection: true,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: labelStyle,
          hintText: hint,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, thickness: 1, color: Colors.black12);
  }
}
