import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:student_platform/src/services/push/notification_preferences_api.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';

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
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Уведомления')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                _OsStatusCard(
                  enabled: _osEnabled,
                  onOpenSettings: () => PushNotificationService.instance
                      .openSystemNotificationSettings(),
                ),
                const SizedBox(height: 18),
                _SectionLabel('Сообщения и друзья'),
                _PrefTile(
                  title: 'Личные сообщения',
                  value: _prefs.dmMessages,
                  enabled: !_saving,
                  onChanged: (v) => _patch({'dm_messages': v}),
                ),
                _PrefTile(
                  title: 'Друзья',
                  subtitle: 'Заявки и принятие',
                  value: _prefs.friendRequests && _prefs.friendAccepts,
                  enabled: !_saving,
                  onChanged: (v) => _patch({
                    'friend_requests': v,
                    'friend_accepts': v,
                  }),
                ),
                const SizedBox(height: 12),
                _SectionLabel('Учёба'),
                _PrefTile(
                  title: 'Задания и учёба',
                  value: _prefs.studyAssignments,
                  enabled: !_saving,
                  onChanged: (v) => _patch({'study_assignments': v}),
                ),
                _PrefTile(
                  title: 'Изменения расписания',
                  value: _prefs.scheduleChanges,
                  enabled: !_saving,
                  onChanged: (v) => _patch({'schedule_changes': v}),
                ),
                const SizedBox(height: 12),
                _SectionLabel('Группы'),
                _PrefTile(
                  title: 'Ответы в группах',
                  value: _prefs.groupReplies,
                  enabled: !_saving,
                  onChanged: (v) => _patch({'group_replies': v}),
                ),
                _PrefTile(
                  title: 'Все сообщения групп',
                  value: _prefs.groupAllMessages,
                  enabled: !_saving,
                  onChanged: (v) => _patch({'group_all_messages': v}),
                ),
                const SizedBox(height: 12),
                _SectionLabel('Конфиденциальность'),
                _PrefTile(
                  title: 'Показывать текст сообщений',
                  value: _prefs.showMessagePreview,
                  enabled: !_saving,
                  onChanged: (v) => _patch({'show_message_preview': v}),
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 16),
                  Text(
                    'OS status: $_osStatus',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.45),
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
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                enabled
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                color: enabled ? cs.primary : cs.error,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  enabled
                      ? 'Уведомления включены'
                      : 'Уведомления отключены в настройках устройства',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          if (!enabled) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onOpenSettings,
              child: const Text('Открыть настройки'),
            ),
          ] else ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: onOpenSettings,
              child: const Text('Открыть настройки устройства'),
            ),
          ],
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
      padding: const EdgeInsets.only(bottom: 6, left: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.62),
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _PrefTile extends StatelessWidget {
  const _PrefTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: SwitchListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle == null ? null : Text(subtitle!),
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}
