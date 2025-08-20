// lib/src/ui/authentication/screens/register_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.toggleView});
  final VoidCallback toggleView;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _loginCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _nameCtrl  = TextEditingController();
  final _surnameCtrl = TextEditingController();
  final _univCtrl  = TextEditingController(text: 'СПбГАСУ');
  final _groupCtrl = TextEditingController(text: '1-См(ВВ)-2');

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _loginCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    _surnameCtrl.dispose();
    _univCtrl.dispose();
    _groupCtrl.dispose();
    super.dispose();
  }

  String _toEmail(String login) =>
      login.contains('@') ? login.trim().toLowerCase() : '${login.trim().toLowerCase()}@app.local';

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });

    final sb = Supabase.instance.client;
    final login = _loginCtrl.text.trim();
    final pass  = _passCtrl.text;

    try {
      // 1) создаём через RPC (auth + profile + team/chat)
      await sb.rpc('register_local_user', params: {
        'p_login'     : login,
        'p_password'  : pass,
        'p_name'      : _nameCtrl.text.trim(),
        'p_surname'   : _surnameCtrl.text.trim(),
        'p_university': _univCtrl.text.trim(),
        'p_group'     : _groupCtrl.text.trim(),
      });

      // 2) и сразу логинимся
      await sb.auth.signInWithPassword(email: _toEmail(login), password: pass);

      if (!mounted) return;
      context.go('/home');
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget field(String label, TextEditingController c,
        {bool obscure=false, TextInputType? type, String? Function(String?)? validator}) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: TextFormField(
          controller: c,
          obscureText: obscure,
          keyboardType: type,
          validator: validator,
          decoration: InputDecoration(labelText: label, filled: true),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Регистрация'), centerTitle: true),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.only(top: 8),
          children: [
            field('Логин (№ зачётки)', _loginCtrl,
              type: TextInputType.text,
              validator: (v) => (v==null||v.trim().isEmpty) ? 'Введите логин' : null),
            field('Пароль', _passCtrl, obscure: true,
              validator: (v) => (v==null||v.trim().length<3) ? 'Минимум 3 символа' : null),

            const Divider(),
            field('Имя', _nameCtrl),
            field('Фамилия', _surnameCtrl),
            field('Университет', _univCtrl),
            field('Группа', _groupCtrl),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: _loading ? null : _register,
                child: _loading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Создать аккаунт'),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: widget.toggleView,
              child: const Text('У меня уже есть аккаунт'),
            ),
          ],
        ),
      ),
    );
  }
}
