import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:student_platform/src/services/push/notification_preferences_api.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';

/// Soft lilac palette shared with Profile.
class _N {
  static const bg = Color(0xFFFAF8FC);
  static const lavender = Color(0xFF7C63D8);
  static const lavenderSoft = Color(0xFFDCD0FA);
  static const lavenderMid = Color(0xFFC9B8F3);
  static const ink = Color(0xFF1C1B1F);
  static const muted = Color(0xFF6B6578);
  static const card = Colors.white;
}

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  final _api = NotificationPreferencesApi();
  NotificationPreferences _prefs = NotificationPreferences.defaults();
  AuthorizationStatus _osStatus = AuthorizationStatus.notDetermined;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final prefs = await _api.getMine();
    final os =
        await PushNotificationService.instance.currentAuthorizationStatus();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _osStatus = os;
      _loading = false;
    });
  }

  bool get _osEnabled =>
      _osStatus == AuthorizationStatus.authorized ||
      _osStatus == AuthorizationStatus.provisional;

  Future<void> _patch(Map<String, dynamic> patch) async {
    setState(() => _saving = true);
    try {
      final next = await _api.updateMine(patch);
      if (!mounted) return;
      setState(() => _prefs = next);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить настройки')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _N.bg,
      appBar: AppBar(
        backgroundColor: _N.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarBrightness: Brightness.light,
          statusBarIconBrightness: Brightness.dark,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          'Уведомления',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: _N.ink,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _N.lavender),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
              children: [
                _OsStatusCard(
                  enabled: _osEnabled,
                  onOpenSettings: () => PushNotificationService.instance
                      .openSystemNotificationSettings(),
                ),
                const SizedBox(height: 22),
                const _SectionLabel('Сообщения и друзья'),
                _PrefGroup(
                  children: [
                    _PrefRow(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: 'Личные сообщения',
                      subtitle: 'Новые диалоги и ответы',
                      value: _prefs.dmMessages,
                      enabled: !_saving,
                      onChanged: (v) => _patch({'dm_messages': v}),
                      showDivider: true,
                    ),
                    _PrefRow(
                      icon: Icons.people_outline_rounded,
                      title: 'Друзья',
                      subtitle: 'Заявки и принятие',
                      value: _prefs.friendRequests && _prefs.friendAccepts,
                      enabled: !_saving,
                      onChanged: (v) => _patch({
                        'friend_requests': v,
                        'friend_accepts': v,
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const _SectionLabel('Учёба'),
                _PrefGroup(
                  children: [
                    _PrefRow(
                      icon: Icons.assignment_outlined,
                      title: 'Задания и учёба',
                      subtitle: 'Новые работы и дедлайны',
                      value: _prefs.studyAssignments,
                      enabled: !_saving,
                      onChanged: (v) => _patch({'study_assignments': v}),
                      showDivider: true,
                    ),
                    _PrefRow(
                      icon: Icons.calendar_today_outlined,
                      title: 'Изменения расписания',
                      subtitle: 'Переносы и отмены пар',
                      value: _prefs.scheduleChanges,
                      enabled: !_saving,
                      onChanged: (v) => _patch({'schedule_changes': v}),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const _SectionLabel('Группы'),
                _PrefGroup(
                  children: [
                    _PrefRow(
                      icon: Icons.reply_rounded,
                      title: 'Ответы в группах',
                      subtitle: 'Когда отвечают вам',
                      value: _prefs.groupReplies,
                      enabled: !_saving,
                      onChanged: (v) => _patch({'group_replies': v}),
                      showDivider: true,
                    ),
                    _PrefRow(
                      icon: Icons.forum_outlined,
                      title: 'Все сообщения групп',
                      subtitle: 'Каждое сообщение команды',
                      value: _prefs.groupAllMessages,
                      enabled: !_saving,
                      onChanged: (v) => _patch({'group_all_messages': v}),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const _SectionLabel('Конфиденциальность'),
                _PrefGroup(
                  children: [
                    _PrefRow(
                      icon: Icons.visibility_outlined,
                      title: 'Текст в уведомлении',
                      subtitle: 'Показывать превью сообщения',
                      value: _prefs.showMessagePreview,
                      enabled: !_saving,
                      onChanged: (v) => _patch({'show_message_preview': v}),
                    ),
                  ],
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 20),
                  Text(
                    'OS status: $_osStatus',
                    style: const TextStyle(
                      fontSize: 12,
                      color: _N.muted,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _OsStatusCard extends StatelessWidget {
  const _OsStatusCard({
    required this.enabled,
    required this.onOpenSettings,
  });

  final bool enabled;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [_N.lavenderSoft, _N.lavenderMid],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: _N.lavenderMid.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  enabled
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_outlined,
                  color: enabled ? _N.lavender : const Color(0xFFB42318),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      enabled
                          ? 'Уведомления включены'
                          : 'Отключены на устройстве',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: _N.ink,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      enabled
                          ? 'Пуши приходят, пока разрешены в системе'
                          : 'Разрешите уведомления в настройках iOS',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: _N.muted,
                            height: 1.25,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onOpenSettings,
              style: FilledButton.styleFrom(
                backgroundColor: enabled ? Colors.white : _N.lavender,
                foregroundColor: enabled ? _N.lavender : Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              child: Text(
                enabled
                    ? 'Настройки устройства'
                    : 'Открыть настройки',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w700,
          color: _N.muted,
        ),
      ),
    );
  }
}

class _PrefGroup extends StatelessWidget {
  const _PrefGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _N.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8E4F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }
}

class _PrefRow extends StatelessWidget {
  const _PrefRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
    this.showDivider = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final bool enabled;
  final bool showDivider;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _N.lavenderSoft.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: _N.lavender, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: _N.ink,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: _N.muted,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch.adaptive(
                value: value,
                onChanged: enabled ? onChanged : null,
                activeThumbColor: _N.lavender,
                activeTrackColor: _N.lavender.withValues(alpha: 0.38),
              ),
            ],
          ),
        ),
        if (showDivider)
          const Divider(
            height: 1,
            thickness: 1,
            indent: 64,
            endIndent: 14,
            color: Color(0xFFEDEAF4),
          ),
      ],
    );
  }
}
