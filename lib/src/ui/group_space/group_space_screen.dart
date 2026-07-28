import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../learning/models/team.dart';
import '../learning/team_details_screen.dart';
import 'data/group_space_repository.dart';
import 'models/group_space.dart';

/// Permanent academic group space: chat entry, collections, topic selection.
class GroupSpaceScreen extends StatefulWidget {
  const GroupSpaceScreen({
    super.key,
    this.repository,
    this.createIfMissing = true,
  });

  final GroupSpaceRepository? repository;
  final bool createIfMissing;

  @override
  State<GroupSpaceScreen> createState() => _GroupSpaceScreenState();
}

class _GroupSpaceScreenState extends State<GroupSpaceScreen> {
  late final GroupSpaceRepository _repo =
      widget.repository ?? GroupSpaceRepository();

  GroupSpaceSnapshot? _space;
  List<GroupCollection> _collections = const [];
  List<GroupTopicSelection> _topics = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final cached = await _repo.peekCachedSpace();
    if (cached != null && cached.exists && mounted) {
      setState(() {
        _space = cached;
        _loading = false;
      });
    }
    await _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
      if (_space == null) _loading = true;
    });
    try {
      final space = await _repo.getMySpace(
        createIfMissing: widget.createIfMissing,
      );
      List<GroupCollection> collections = const [];
      List<GroupTopicSelection> topics = const [];
      if (space.exists) {
        collections = await _repo.listCollections();
        topics = await _repo.listTopicSelections();
      }
      if (!mounted) return;
      setState(() {
        _space = space;
        _collections = collections;
        _topics = topics;
        _loading = false;
        if (!space.exists) {
          _error = 'Общий чат группы пока недоступен';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить чат группы';
      });
    }
  }

  Future<void> _openChat() async {
    final space = _space;
    if (space == null || !space.exists) return;
    final team = Team(
      id: space.teamId!,
      name: space.title ?? 'Общий чат группы',
      teacher: '',
      icon: 'groups',
      groupCode: '',
      groupId: space.groupId,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeamDetailsScreen(
          team: team,
          initialTabIndex: 1,
        ),
      ),
    );
  }

  Future<void> _createCollection() async {
    final space = _space;
    if (space == null || !space.isOrganizer) return;
    final titleCtrl = TextEditingController();
    final purposeCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый сбор'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            TextField(
              controller: purposeCtrl,
              decoration: const InputDecoration(labelText: 'Цель'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtrl.text.trim();
    if (title.isEmpty) return;
    try {
      await _repo.createCollection(
        title: title,
        purpose: purposeCtrl.text.trim(),
      );
      await _reload();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать сбор')),
      );
    }
  }

  Future<void> _openCollection(GroupCollection collection) async {
    final space = _space;
    if (space == null || !space.exists) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _CollectionDetailScreen(
          repository: _repo,
          collection: collection,
          isOrganizer: space.isOrganizer,
          chatId: space.chatId!,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _openTopic(GroupTopicSelection selection) async {
    final space = _space;
    if (space == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TopicDetailScreen(
          repository: _repo,
          selection: selection,
          isOrganizer: space.isOrganizer,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _createTopic() async {
    final space = _space;
    if (space == null || !space.isOrganizer) return;
    final titleCtrl = TextEditingController();
    final option1Ctrl = TextEditingController();
    final option2Ctrl = TextEditingController();
    final capacityCtrl = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выбор темы'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            TextField(
              controller: option1Ctrl,
              decoration: const InputDecoration(labelText: 'Тема 1'),
            ),
            TextField(
              controller: option2Ctrl,
              decoration: const InputDecoration(labelText: 'Тема 2'),
            ),
            TextField(
              controller: capacityCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Мест на тему'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtrl.text.trim();
    final option1 = option1Ctrl.text.trim();
    final option2 = option2Ctrl.text.trim();
    final capacity = int.tryParse(capacityCtrl.text.trim()) ?? 0;
    if (title.isEmpty || option1.isEmpty || option2.isEmpty || capacity < 1) {
      return;
    }
    try {
      final id = await _repo.createTopicSelection(title: title);
      await _repo.addTopicOption(
        selectionId: id,
        title: option1,
        capacity: capacity,
        sortOrder: 0,
      );
      await _repo.addTopicOption(
        selectionId: id,
        title: option2,
        capacity: capacity,
        sortOrder: 1,
      );
      await _reload();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать выбор темы')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final space = _space;

    return Scaffold(
      appBar: AppBar(
        title: Text(space?.title ?? 'Чат группы'),
      ),
      body: _loading && space == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text(_error!),
                        subtitle: const Text(
                          'Если вы уже в учебной группе, потяните вниз, чтобы обновить.',
                        ),
                      ),
                    ),
                  if (space != null && space.exists) ...[
                    FilledButton.icon(
                      onPressed: _openChat,
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Открыть общий чат группы'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      space.isOrganizer
                          ? 'Вы организатор чата группы'
                          : 'Участник учебной группы',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _SectionHeader(
                      title: 'Сбор группы',
                      actionLabel: space.isOrganizer ? 'Создать' : null,
                      onAction: space.isOrganizer ? _createCollection : null,
                    ),
                    if (_collections.isEmpty)
                      const _EmptyHint('Активных сборов пока нет')
                    else
                      ..._collections.map(
                        (c) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(c.title),
                          subtitle: Text(
                            [
                              if (c.purpose.trim().isNotEmpty) c.purpose,
                              'Статус: ${c.status}',
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openCollection(c),
                        ),
                      ),
                    const SizedBox(height: 16),
                    _SectionHeader(
                      title: 'Выбор темы',
                      actionLabel: space.isOrganizer ? 'Создать' : null,
                      onAction: space.isOrganizer ? _createTopic : null,
                    ),
                    if (_topics.isEmpty)
                      const _EmptyHint('Выборов темы пока нет')
                    else
                      ..._topics.map(
                        (t) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(t.title),
                          subtitle: Text('Статус: ${t.status}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openTopic(t),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.black45,
            ),
      ),
    );
  }
}

class _CollectionDetailScreen extends StatefulWidget {
  const _CollectionDetailScreen({
    required this.repository,
    required this.collection,
    required this.isOrganizer,
    required this.chatId,
  });

  final GroupSpaceRepository repository;
  final GroupCollection collection;
  final bool isOrganizer;
  final String chatId;

  @override
  State<_CollectionDetailScreen> createState() =>
      _CollectionDetailScreenState();
}

class _CollectionDetailScreenState extends State<_CollectionDetailScreen> {
  final _commentCtrl = TextEditingController();
  String _participation = 'joining';
  bool _saving = false;
  String? _proofPath;
  String? _proofFileId;
  List<Map<String, dynamic>> _contributions = const [];

  @override
  void initState() {
    super.initState();
    if (widget.isOrganizer) {
      _loadContributions();
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  String _paymentStatusLabel(String status) {
    switch (status) {
      case 'reported':
      case 'pending_review':
        return 'Участник сообщил';
      case 'confirmed':
        return 'Получено';
      case 'not_received':
        return 'Не поступило';
      case 'needs_clarification':
      case 'rejected':
        return 'Нужно уточнение';
      case 'unmarked':
      default:
        return 'Не отмечено';
    }
  }

  Future<void> _loadContributions() async {
    try {
      final rows = await widget.repository
          .listCollectionContributions(widget.collection.id);
      if (!mounted) return;
      setState(() => _contributions = rows);
    } catch (_) {}
  }

  Future<void> _pickProof() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      _proofPath = picked.path;
      _proofFileId = null;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      var proofId = _proofFileId;
      if (_proofPath != null && proofId == null) {
        proofId = await widget.repository.uploadProofFile(
          chatId: widget.chatId,
          localPath: _proofPath!,
        );
        _proofFileId = proofId;
      }
      await widget.repository.upsertMyContribution(
        collectionId: widget.collection.id,
        participationStatus: _participation,
        paymentStatus: _participation == 'joining' ? 'reported' : 'unmarked',
        comment: _commentCtrl.text.trim(),
        proofFileId: proofId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Отметка «Я перевёл» сохранена')),
      );
      if (widget.isOrganizer) {
        await _loadContributions();
      } else {
        Navigator.pop(context);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить отметку')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.collection;
    return Scaffold(
      appBar: AppBar(title: Text(c.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (c.purpose.trim().isNotEmpty) Text(c.purpose),
          if (c.description.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(c.description),
          ],
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _participation,
            items: const [
              DropdownMenuItem(value: 'joining', child: Text('Участвую')),
              DropdownMenuItem(value: 'declined', child: Text('Не участвую')),
              DropdownMenuItem(value: 'unmarked', child: Text('Пока не решил')),
            ],
            onChanged: c.isOpen
                ? (v) => setState(() => _participation = v ?? 'joining')
                : null,
            decoration: const InputDecoration(labelText: 'Участие'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _commentCtrl,
            enabled: c.isOpen,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Комментарий',
              helperText:
                  'Не указывайте платёжные реквизиты и лишние финансовые данные',
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: c.isOpen ? _pickProof : null,
            icon: const Icon(Icons.photo_outlined),
            label: Text(
              _proofPath == null
                  ? 'Прикрепить подтверждающий скриншот'
                  : 'Скриншот выбран',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: c.isOpen && !_saving ? _save : null,
            child: Text(_saving ? 'Сохранение…' : 'Я перевёл'),
          ),
          if (widget.isOrganizer) ...[
            const SizedBox(height: 20),
            Text(
              'Участники',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            if (_contributions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Отметок пока нет'),
              )
            else
              ..._contributions.map((row) {
                final userId = row['user_id']?.toString() ?? '';
                final payment = row['payment_status']?.toString() ?? 'unmarked';
                final proofUrl = row['proof_file_url']?.toString() ?? '';
                final hasProof = proofUrl.isNotEmpty ||
                    (row['proof_file_id']?.toString() ?? '').isNotEmpty;
                final canReview = payment != 'confirmed';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(userId),
                  subtitle: Text(
                    '${_paymentStatusLabel(payment)}'
                    '${hasProof ? ' · есть подтверждение' : ''}',
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      if (proofUrl.isNotEmpty)
                        IconButton(
                          tooltip: 'Открыть подтверждение',
                          onPressed: () async {
                            final uri = Uri.tryParse(proofUrl);
                            if (uri == null) return;
                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          icon: const Icon(Icons.open_in_new),
                        ),
                      if (canReview) ...[
                        IconButton(
                          tooltip: 'Получено',
                          onPressed: () async {
                            await widget.repository.confirmContribution(
                              collectionId: c.id,
                              userId: userId,
                              paymentStatus: 'confirmed',
                            );
                            await _loadContributions();
                          },
                          icon: const Icon(Icons.check_circle_outline),
                        ),
                        IconButton(
                          tooltip: 'Не поступило',
                          onPressed: () async {
                            await widget.repository.confirmContribution(
                              collectionId: c.id,
                              userId: userId,
                              paymentStatus: 'not_received',
                            );
                            await _loadContributions();
                          },
                          icon: const Icon(Icons.cancel_outlined),
                        ),
                        IconButton(
                          tooltip: 'Нужно уточнение',
                          onPressed: () async {
                            await widget.repository.confirmContribution(
                              collectionId: c.id,
                              userId: userId,
                              paymentStatus: 'needs_clarification',
                            );
                            await _loadContributions();
                          },
                          icon: const Icon(Icons.help_outline),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            if (c.isOpen) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  await widget.repository.updateCollectionStatus(
                    collectionId: c.id,
                    status: 'closed',
                  );
                  if (mounted) Navigator.pop(context);
                },
                child: const Text('Закрыть'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _TopicDetailScreen extends StatefulWidget {
  const _TopicDetailScreen({
    required this.repository,
    required this.selection,
    required this.isOrganizer,
  });

  final GroupSpaceRepository repository;
  final GroupTopicSelection selection;
  final bool isOrganizer;

  @override
  State<_TopicDetailScreen> createState() => _TopicDetailScreenState();
}

class _TopicDetailScreenState extends State<_TopicDetailScreen> {
  List<GroupTopicOption> _options = const [];
  String? _myPick;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final options =
          await widget.repository.listTopicOptions(widget.selection.id);
      final mine = await widget.repository.myTopicPick(widget.selection.id);
      if (!mounted) return;
      setState(() {
        _options = options;
        _myPick = mine;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить темы';
      });
    }
  }

  Future<void> _pick(GroupTopicOption option) async {
    try {
      await widget.repository.pickTopic(
        selectionId: widget.selection.id,
        optionId: option.id,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('option_full')
          ? 'Мест больше нет'
          : 'Не удалось выбрать тему';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      await _load();
    }
  }

  Future<void> _addOption() async {
    final titleCtrl = TextEditingController();
    final capacityCtrl = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить тему'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: 'Название темы'),
            ),
            TextField(
              controller: capacityCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Количество мест'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtrl.text.trim();
    final capacity = int.tryParse(capacityCtrl.text.trim()) ?? 0;
    if (title.isEmpty || capacity < 1) return;
    try {
      await widget.repository.addTopicOption(
        selectionId: widget.selection.id,
        title: title,
        capacity: capacity,
        sortOrder: _options.length,
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось добавить тему')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.selection.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) Text(_error!),
                  if (widget.selection.description.trim().isNotEmpty)
                    Text(widget.selection.description),
                  const SizedBox(height: 12),
                  ..._options.map(
                    (o) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(o.title),
                      subtitle:
                          Text('Свободно: ${o.freeSlots} из ${o.capacity}'),
                      trailing: _myPick == o.id
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : TextButton(
                              onPressed: widget.selection.isOpen && !o.isFull
                                  ? () => _pick(o)
                                  : null,
                              child: const Text('Выбрать'),
                            ),
                    ),
                  ),
                  if (widget.isOrganizer && widget.selection.isOpen)
                    TextButton(
                      onPressed: _addOption,
                      child: const Text('Добавить тему'),
                    ),
                  if (_myPick != null &&
                      widget.selection.isOpen &&
                      widget.selection.allowChange)
                    TextButton(
                      onPressed: () async {
                        await widget.repository
                            .cancelTopicPick(widget.selection.id);
                        await _load();
                      },
                      child: const Text('Отменить выбор'),
                    ),
                  if (widget.isOrganizer && widget.selection.isOpen)
                    OutlinedButton(
                      onPressed: () async {
                        await widget.repository.closeTopicSelection(
                          selectionId: widget.selection.id,
                        );
                        if (mounted) Navigator.pop(context);
                      },
                      child: const Text('Закрыть выбор'),
                    ),
                ],
              ),
            ),
    );
  }
}
