import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.toggleView});
  final VoidCallback toggleView;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _loginCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _hidePassword = true;
  bool _loading = false;

  final _sb = Supabase.instance.client;

  static const _authDomain = 'app.local';
  String _loginToEmail(String input) {
    final v = input.trim().toLowerCase();
    if (v.contains('@')) return v;
    return '$v@$_authDomain';
  }

  Future<void> _doLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    final login = _loginCtrl.text.trim();
    final pass = _passCtrl.text;

    try {
      // 1) Auth login (email = "<login>@app.local")
      final email = _loginToEmail(login);
      await _sb.auth.signInWithPassword(email: email, password: pass);

      // 2) Профиль. Сначала RPC (устойчиво к рассинхрону id/login),
      //    если не вернул — прямой select по id.
      Map<String, dynamic>? data;

      try {
        final rows = await _sb.rpc('get_my_profile') as List?;
        if (rows != null && rows.isNotEmpty) {
          data = Map<String, dynamic>.from(rows.first as Map);
        }
      } catch (_) {
        // упадём в план Б ниже
      }

      if (data == null) {
        final uid = _sb.auth.currentUser?.id;
        if (uid == null) throw 'Не удалось получить сессию';
        final row = await _sb
            .from('users')
            .select('id, login, name, surname, university, group_name, avatar_url, status, role')
            .eq('id', uid)
            .maybeSingle();

        if (row == null) throw 'Профиль не найден';
        data = Map<String, dynamic>.from(row as Map);
      }

      // 3) Сохраняем локально и идём на /home
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('loggedIn', true);
      await prefs.setString('user', jsonEncode(data));

      if (!mounted) return;
      try {
        context.go('/home');
      } catch (_) {
        Navigator.of(context).pushReplacementNamed('/home');
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      // Показываем исходную ошибку, чтобы ловить серверные проблемы
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _loginCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('Вход'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              const SizedBox(height: 8),
              SizedBox(
                height: 200,
                child: Lottie.asset('assets/lottie/cat_sleeping.json'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      _buildField(
                        label: 'Логин (№ зачётки) или email',
                        controller: _loginCtrl,
                        keyboardType: TextInputType.text,
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Введите логин' : null,
                      ),
                      const Divider(height: 1),
                      _buildField(
                        label: 'Пароль',
                        controller: _passCtrl,
                        obscure: _hidePassword,
                        validator: (v) => (v == null || v.trim().length < 4) ? 'Минимум 4 символа' : null,
                        suffix: IconButton(
                          onPressed: () => setState(() => _hidePassword = !_hidePassword),
                          icon: Icon(_hidePassword ? Icons.visibility_off : Icons.visibility),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: widget.toggleView,
                child: const Text('Нет аккаунта? Зарегистрироваться'),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _doLogin,
                    child: _loading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Войти'),
                  ),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('© ${DateTime.now().year} Student Platform', style: theme.textTheme.bodySmall),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: TextFormField(
        controller: controller,
        validator: validator,
        keyboardType: keyboardType,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          border: InputBorder.none,
          suffixIcon: suffix,
        ),
      ),
    );
  }
}
