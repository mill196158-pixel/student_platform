import 'package:flutter/material.dart';

import '../news_item.dart';
import '../news_repository.dart';

/// Stage 15.2 audience controls for the news editor.
///
/// When [normalizedAvailable] is false, multi-group/user controls stay disabled
/// (fail-closed dual-read). Legacy all stays available.
class NewsAudiencePanel extends StatefulWidget {
  const NewsAudiencePanel({
    super.key,
    required this.item,
    required this.enabled,
    required this.normalizedAvailable,
    required this.onSave,
    required this.onPreview,
  });

  final NewsItem item;
  final bool enabled;
  final bool normalizedAvailable;
  final Future<void> Function({
    required NewsAudienceMode mode,
    required List<String> groupIds,
    required List<String> userIds,
  }) onSave;
  final Future<NewsAudiencePreview> Function() onPreview;

  @override
  State<NewsAudiencePanel> createState() => _NewsAudiencePanelState();
}

class _NewsAudiencePanelState extends State<NewsAudiencePanel> {
  late NewsAudienceMode _mode = widget.item.audienceMode;
  late final TextEditingController _groups = TextEditingController(
    text: widget.item.audienceGroupIds.join(', '),
  );
  late final TextEditingController _users = TextEditingController(
    text: widget.item.audienceUserIds.join(', '),
  );
  NewsAudiencePreview? _preview;
  String? _banner;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant NewsAudiencePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.versionNumber != widget.item.versionNumber) {
      _mode = widget.item.audienceMode;
      _groups.text = widget.item.audienceGroupIds.join(', ');
      _users.text = widget.item.audienceUserIds.join(', ');
      _preview = null;
      _banner = null;
    }
  }

  @override
  void dispose() {
    _groups.dispose();
    _users.dispose();
    super.dispose();
  }

  List<String> _split(String raw) => raw
      .split(RegExp(r'[\s,;]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await widget.onSave(
        mode: _mode,
        groupIds: _split(_groups.text),
        userIds: _split(_users.text),
      );
      if (!mounted) return;
      setState(() => _banner = 'Аудитория сохранена.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewTap() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      final preview = await widget.onPreview();
      if (!mounted) return;
      setState(() => _preview = preview);
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canUseNormalized = widget.normalizedAvailable && widget.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Аудитория',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (!widget.normalizedAvailable)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'RPC Stage 15.2 не применён: доступны legacy «все» и ровно '
              'одна группа. Multi-group/users отключены fail-closed.',
            ),
          ),
        const SizedBox(height: 8),
        DropdownButtonFormField<NewsAudienceMode>(
          initialValue: (_mode == NewsAudienceMode.all ||
                  _mode == NewsAudienceMode.groups ||
                  canUseNormalized)
              ? (_mode == NewsAudienceMode.users ||
                      _mode == NewsAudienceMode.groupsAndUsers
                  ? NewsAudienceMode.all
                  : _mode)
              : NewsAudienceMode.all,
          decoration: const InputDecoration(labelText: 'Режим'),
          items: [
            const DropdownMenuItem(
              value: NewsAudienceMode.all,
              child: Text('Все студенты'),
            ),
            const DropdownMenuItem(
              value: NewsAudienceMode.groups,
              child: Text(
                'Группа(ы)',
              ),
            ),
            if (canUseNormalized) ...const [
              DropdownMenuItem(
                value: NewsAudienceMode.users,
                child: Text('Явный набор пользователей'),
              ),
              DropdownMenuItem(
                value: NewsAudienceMode.groupsAndUsers,
                child: Text('Группы и пользователи'),
              ),
            ],
          ],
          onChanged: !widget.enabled
              ? null
              : (value) {
                  if (value == null) return;
                  if (!canUseNormalized &&
                      value != NewsAudienceMode.all &&
                      value != NewsAudienceMode.groups) {
                    return;
                  }
                  setState(() => _mode = value);
                },
        ),
        if (_mode != NewsAudienceMode.all) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _groups,
            enabled: widget.enabled &&
                (_mode == NewsAudienceMode.groups ||
                    _mode == NewsAudienceMode.groupsAndUsers),
            decoration: InputDecoration(
              labelText: canUseNormalized
                  ? 'Group IDs (UUID через запятую)'
                  : 'Один Group ID (legacy)',
              helperText: canUseNormalized
                  ? null
                  : 'Без Stage 15.2 RPC допускается ровно одна группа.',
            ),
          ),
          if (canUseNormalized) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _users,
              enabled: widget.enabled &&
                  (_mode == NewsAudienceMode.users ||
                      _mode == NewsAudienceMode.groupsAndUsers),
              decoration: const InputDecoration(
                labelText: 'User IDs (UUID через запятую)',
              ),
            ),
          ],
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: widget.enabled && !_busy ? _save : null,
              child: const Text('Сохранить аудиторию'),
            ),
            OutlinedButton(
              onPressed: widget.enabled &&
                      widget.normalizedAvailable &&
                      !_busy
                  ? _previewTap
                  : null,
              child: const Text('Preview получателей'),
            ),
          ],
        ),
        if (_preview != null) ...[
          const SizedBox(height: 8),
          Text(
            'Получателей: ${_preview!.recipientCount} · '
            'групп: ${_preview!.groupCount} · '
            'явных пользователей: ${_preview!.explicitUserCount}',
          ),
        ],
        if (_banner != null) ...[
          const SizedBox(height: 8),
          Text(_banner!),
        ],
      ],
    );
  }
}
