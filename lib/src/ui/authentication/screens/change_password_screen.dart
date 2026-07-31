import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  bool _hidePassword = true;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    final sb = Supabase.instance.client;

    try {
      final userId = sb.auth.currentUser?.id;
      if (userId == null) {
        throw 'Не удалось получить текущего пользователя';
      }

      await sb.auth.updateUser(UserAttributes(password: _passwordCtrl.text));
      // must_change_password is cleared server-side by an auth.users password trigger.

      final prefs = await SharedPreferences.getInstance();
      final cachedUser = prefs.getString('user');
      if (cachedUser != null) {
        final decoded = jsonDecode(cachedUser);
        if (decoded is Map<String, dynamic>) {
          decoded['must_change_password'] = false;
          await prefs.setString('user', jsonEncode(decoded));
        }
      }

      if (!mounted) return;
      context.go('/home');
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Смена пароля'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.zero,
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
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          'Для первого входа нужно заменить временный пароль на новый.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildField(
                        label: 'Новый пароль',
                        controller: _passwordCtrl,
                        obscure: _hidePassword,
                        validator: (value) {
                          if (value == null || value.length < 6) {
                            return 'Минимум 6 символов';
                          }
                          return null;
                        },
                        suffix: IconButton(
                          onPressed: () =>
                              setState(() => _hidePassword = !_hidePassword),
                          icon: Icon(_hidePassword
                              ? Icons.visibility_off
                              : Icons.visibility),
                        ),
                      ),
                      const Divider(height: 1),
                      _buildField(
                        label: 'Повторите пароль',
                        controller: _confirmCtrl,
                        obscure: _hidePassword,
                        validator: (value) {
                          if (value != _passwordCtrl.text) {
                            return 'Пароли не совпадают';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Сохранить пароль'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '© ${DateTime.now().year} Student Platform',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 8),
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
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: TextFormField(
        controller: controller,
        validator: validator,
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
