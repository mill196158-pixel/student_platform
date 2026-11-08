import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/legacy_user_cache.dart';
import '../../themes/theme_service.dart';
import 'theme_mode_picker.dart';
import 'cache_diagnostics_screen.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const String _fixedUniversity = 'СПБГАСУ';

  final _formKey = GlobalKey<FormState>();

  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _university = TextEditingController(text: _fixedUniversity);
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
  String? _avatarUrl; // url из БД

  bool _saving = false;
  Map<String, dynamic>? _user;

  final _sb = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final initial = _sb.auth.currentSession;
    if (initial == null) return;
    final owner = (initial.user.id, initial.accessToken, initial.refreshToken);
    final user = await LegacyUserCache.read(currentSession: () => _sb.auth.currentSession);
    if (!mounted) return;
    final current = _sb.auth.currentSession;
    if (current == null ||
        (current.user.id, current.accessToken, current.refreshToken) != owner) return;
    if (user != null) {
      _user = user;
      _firstName.text = (_user?['name'] ?? '') as String;
      _lastName.text = (_user?['surname'] ?? '') as String;
      _university.text = _fixedUniversity;
      _group.text = (_user?['group_name'] ?? '') as String;
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
    final picked =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
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

  Future<void> _openStatusPicker() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _StatusPickerSheet(
        statuses: _statuses,
        current: _status,
      ),
    );
    if (picked == null || picked == _status) return;
    await _setStatus(picked);
  }

  Future<void> _openChangePassword() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _ChangePasswordSheet(),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пароль изменён')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    ImageProvider? avatarProvider;
    if (_avatarPath != null) {
      avatarProvider = FileImage(File(_avatarPath!));
    } else if (_avatarUrl != null && _avatarUrl!.isNotEmpty) {
      avatarProvider = CachedNetworkImageProvider(_avatarUrl!);
    }

    return Scaffold(
      backgroundColor: colors.surfaceContainerLow,
      appBar: AppBar(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Настройки профиля',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: colors.onSurface,
          ),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            style: TextButton.styleFrom(
              foregroundColor: colors.primary,
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
            child: _saving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: ProductLoadingIndicator(
                      color: colors.primary,
                    ),
                  )
                : const Text('Готово'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            Center(
              child: Stack(
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [colors.primaryContainer, colors.secondaryContainer],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Center(
                      child: CircleAvatar(
                        radius: 41,
                        backgroundColor: colors.surface,
                        backgroundImage: avatarProvider,
                        child: avatarProvider == null
                            ? Icon(Icons.person,
                                size: 34, color: colors.onSurfaceVariant)
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
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: colors.primary.withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Icon(Icons.edit,
                            color: colors.onPrimary, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SettingsSectionLabel('Профиль'),
            _ProfileFieldsCard(
              children: [
                _CompactField(
                  label: 'Имя',
                  value: _firstName.text,
                  locked: true,
                ),
                _Divider(),
                _CompactField(
                  label: 'Фамилия',
                  value: _lastName.text,
                  locked: true,
                ),
                _Divider(),
                _CompactField(
                  label: 'Университет',
                  value: _university.text,
                  locked: true,
                ),
                _Divider(),
                _CompactField(
                  label: 'Группа',
                  value: _group.text,
                  locked: true,
                ),
              ],
            ),
            const SizedBox(height: 14),
            const _SettingsSectionLabel('Статус'),
            _ProfileFieldsCard(
              children: [
                Builder(
                  builder: (context) {
                    final visual = _StatusVisual.forLabel(_status);
                    return _SettingsNavRow(
                      icon: visual.icon,
                      iconWidget: Icon(
                        visual.icon,
                        color: visual.color,
                        size: 18,
                      ),
                      title: _status,
                      subtitle: 'Нажмите, чтобы изменить',
                      onTap: _openStatusPicker,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            const _SettingsSectionLabel('Оформление'),
            const _ProfileFieldsCard(children: [_ThemePreference()]),
            const SizedBox(height: 14),
            const _SettingsSectionLabel('Данные'),
            _ProfileFieldsCard(children: [
              _SettingsNavRow(
                icon: Icons.storage_outlined,
                title: 'Данные приложения',
                subtitle: 'Частичная оценка хранилища',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const CacheDiagnosticsScreen(),
                )),
              ),
            ]),
            const SizedBox(height: 14),
            const _SettingsSectionLabel('Безопасность и уведомления'),
            _ProfileFieldsCard(
              children: [
                _SettingsNavRow(
                  icon: Icons.notifications_none_rounded,
                  title: 'Уведомления',
                  subtitle: 'Пуши, сообщения, учёба',
                  onTap: () => context.push('/notification-settings'),
                  showDivider: true,
                ),
                _SettingsNavRow(
                  icon: Icons.lock_outline_rounded,
                  title: 'Сменить пароль',
                  subtitle: 'Новый пароль для входа',
                  onTap: _openChangePassword,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemePreference extends StatefulWidget {
  const _ThemePreference();

  @override
  State<_ThemePreference> createState() => _ThemePreferenceState();
}

class _ThemePreferenceState extends State<_ThemePreference> {
  bool _saving = false;

  Future<void> _openPicker(ThemeMode current) async {
    final mode = await showThemeModePicker(context, current);
    if (!mounted || mode == null || mode == current) return;
    setState(() => _saving = true);
    try {
      await themeService.select(mode);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить тему')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeService,
      builder: (context, mode, _) => _SettingsNavRow(
        icon: Icons.brightness_6_outlined,
        title: 'Тема',
        subtitle: themeModeLabel(mode),
        onTap: _saving ? null : () => _openPicker(mode),
      ),
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w700,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SettingsNavRow extends StatelessWidget {
  const _SettingsNavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = false,
    this.iconWidget,
  });

  final IconData icon;
  final Widget? iconWidget;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    alignment: Alignment.center,
                    child:
                        iconWidget ?? Icon(icon, color: colors.primary, size: 19),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          const Divider(
            height: 1,
            thickness: 1,
            indent: 60,
            endIndent: 14,

          ),
      ],
    );
  }
}

class _StatusPickerSheet extends StatelessWidget {
  const _StatusPickerSheet({
    required this.statuses,
    required this.current,
  });

  final List<String> statuses;
  final String current;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: colors.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Text(
                'Статус',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < statuses.length; i++) ...[
                      if (i > 0)
                        const Divider(
                          height: 1,
                          thickness: 1,
                          indent: 56,
                          endIndent: 14,

                        ),
                      _StatusOptionTile(
                        label: statuses[i],
                        selected: statuses[i] == current,
                        onTap: () => Navigator.of(context).pop(statuses[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusVisual {
  const _StatusVisual(this.icon, this.color);
  final IconData icon;
  final Color color;

  static _StatusVisual forLabel(String label) {
    switch (label) {
      case 'Онлайн':
        return const _StatusVisual(Icons.circle, Color(0xFF34C759));
      case 'Занят 🚫':
        return const _StatusVisual(
            Icons.do_not_disturb_on_rounded, Color(0xFFFF3B30));
      case 'На паре':
        return const _StatusVisual(Icons.school_rounded, Color(0xFF007AFF));
      case 'В библиотеке':
        return const _StatusVisual(Icons.menu_book_rounded, Color(0xFF30B0C7));
      case 'Готовлюсь к сессии 💪':
        return const _StatusVisual(
            Icons.local_fire_department_rounded, Color(0xFFFF9500));
      case 'Отошёл':
        return const _StatusVisual(Icons.schedule_rounded, Color(0xFF8E8E93));
      default:
        return const _StatusVisual(Icons.circle, Color(0xFF7C63D8));
    }
  }
}

class _StatusOptionTile extends StatelessWidget {
  const _StatusOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visual = _StatusVisual.forLabel(label);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: visual.color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(visual.icon, size: 18, color: visual.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: visual.color, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactField extends StatelessWidget {
  const _CompactField({
    required this.label,
    required this.value,
    this.locked = false,
  });

  final String label;
  final String value;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value.isEmpty ? '—' : value,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
          if (locked)
            const Icon(
              Icons.lock_outline_rounded,
              size: 16,
              color: Color(0xFFB7B1C4),
            ),
        ],
      ),
    );
  }
}

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet();

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final a = _newCtrl.text.trim();
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.auth
          .updateUser(UserAttributes(password: a));
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось сменить пароль');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: colors.outlineVariant,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [colors.primaryContainer, colors.secondaryContainer],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      Icons.lock_rounded,
                      color: colors.primary,
                      size: 26,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Сменить пароль',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Придумайте новый пароль — минимум 6 символов',
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _PasswordField(
                    controller: _newCtrl,
                    label: 'Новый пароль',
                    obscure: _obscureNew,
                    onToggle: () => setState(() => _obscureNew = !_obscureNew),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.length < 6) return 'Минимум 6 символов';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  _PasswordField(
                    controller: _confirmCtrl,
                    label: 'Повторите пароль',
                    obscure: _obscureConfirm,
                    onToggle: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                    validator: (v) {
                      if ((v ?? '').trim() != _newCtrl.text.trim()) {
                        return 'Пароли не совпадают';
                      }
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: colors.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: colors.onPrimary,
                      disabledBackgroundColor:
                          colors.primary.withValues(alpha: 0.45),
                      elevation: 0,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    child: _busy
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: ProductLoadingIndicator(
                              color: colors.onPrimary,
                            ),
                          )
                        : const Text('Сохранить пароль'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.onSurfaceVariant,
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    child: const Text('Отмена'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onToggle,
    required this.validator,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onToggle;
  final String? Function(String?) validator;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      validator: validator,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: colors.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
        filled: true,
        fillColor: colors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        suffixIcon: IconButton(
          onPressed: onToggle,
          icon: Icon(
            obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: colors.onSurfaceVariant,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.error, width: 1.6),
        ),
      ),
    );
  }
}

class _ProfileFieldsCard extends StatelessWidget {
  final List<Widget> children;

  const _ProfileFieldsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(children: children),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 1,

    );
  }
}
