import 'package:student_ui/student_ui.dart' show ProductTheme, ProductLoadingIndicator;
import '../../services/chat_file_access.dart';
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
  bool _hasLoadedLists = false;
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
    if (!mounted) return;
    await _reload();
  }

  Future<void> _reload() async {
    if (!mounted) return;
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
        _hasLoadedLists = true;
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
    final values = await showDialog<List<String>>(
        context: context,
        builder: (_) => const _GroupFieldsDialog(
                title: 'Новый сбор',
                action: 'Создать',
                fields: [
                  _GroupField('Название', initial: '', numeric: false),
                  _GroupField('Цель', initial: '', numeric: false),
                ]));
    if (!mounted || values == null) return;
    final title = values[0].trim();
    if (title.isEmpty) return;
    try {
      await _repo.createCollection(
        title: title,
        purpose: values[1].trim(),
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
    final values = await showDialog<List<String>>(
        context: context,
        builder: (_) => const _GroupFieldsDialog(
                title: 'Выбор темы',
                action: 'Создать',
                fields: [
                  _GroupField('Название', initial: '', numeric: false),
                  _GroupField('Тема 1', initial: '', numeric: false),
                  _GroupField('Тема 2', initial: '', numeric: false),
                  _GroupField('Мест на тему', initial: '1', numeric: true),
                ]));
    if (!mounted || values == null) return;
    final title = values[0].trim();
    final option1 = values[1].trim();
    final option2 = values[2].trim();
    final capacity = int.tryParse(values[3].trim()) ?? 0;
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
          ? const Center(child: ProductLoadingIndicator.page())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(
                    vertical: 24,
                    horizontal: ((MediaQuery.sizeOf(context).width - 800) / 2)
                        .clamp(16.0, double.infinity)),
                children: [
                  if (_error != null) ...[
                    _GroupStatePanel(
                      icon: Icons.info_outline,
                      title: _error!,
                      action: TextButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить'),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
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
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (!_hasLoadedLists && _error == null)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: ProductLoadingIndicator(size: 28),
                      ),
                    _SectionHeader(
                      title: 'Сбор группы',
                      actionLabel: space.isOrganizer ? 'Создать' : null,
                      actionTooltip: 'Создать сбор',
                      onAction: space.isOrganizer ? _createCollection : null,
                    ),
                    if (_collections.isEmpty && _hasLoadedLists)
                      const _GroupStatePanel(
                        icon: Icons.receipt_long_outlined,
                        title: 'Активных сборов пока нет',
                      )
                    else if (_collections.isNotEmpty)
                      _GroupRows(
                          children: _collections
                              .map(
                                (c) => ListTile(
                                  leading:
                                      const Icon(Icons.receipt_long_outlined),
                                  title: Text(c.title),
                                  subtitle: Text(
                                    [
                                      if (c.purpose.trim().isNotEmpty)
                                        c.purpose,
                                      _groupStatusLabel(c.status),
                                    ].join(' · '),
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _openCollection(c),
                                ),
                              )
                              .toList()),
                    const SizedBox(height: 16),
                    _SectionHeader(
                      title: 'Выбор темы',
                      actionLabel: space.isOrganizer ? 'Создать' : null,
                      actionTooltip: 'Создать выбор темы',
                      onAction: space.isOrganizer ? _createTopic : null,
                    ),
                    if (_topics.isEmpty && _hasLoadedLists)
                      const _GroupStatePanel(
                        icon: Icons.list_alt_outlined,
                        title: 'Выборов темы пока нет',
                      )
                    else if (_topics.isNotEmpty)
                      _GroupRows(
                          children: _topics
                              .map(
                                (t) => ListTile(
                                  leading: const Icon(Icons.list_alt_outlined),
                                  title: Text(t.title),
                                  subtitle: Text(_groupStatusLabel(t.status)),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _openTopic(t),
                                ),
                              )
                              .toList()),
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
    required this.actionTooltip,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String actionTooltip;
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
          Tooltip(
            message: actionTooltip,
            child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ),
      ],
    );
  }
}

class _GroupRows extends StatelessWidget {
  const _GroupRows({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            child,
          ],
        ],
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
  bool _loadingContributions = false;
  bool _contributionsError = false;

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
    if (!mounted) return;
    setState(() {
      _loadingContributions = true;
      _contributionsError = false;
    });
    try {
      final rows = await widget.repository
          .listCollectionContributions(widget.collection.id);
      if (!mounted) return;
      setState(() {
        _contributions = rows;
        _loadingContributions = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingContributions = false;
        _contributionsError = true;
      });
    }
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
        padding: EdgeInsets.symmetric(
            vertical: 24,
            horizontal: ((MediaQuery.sizeOf(context).width - 800) / 2)
                .clamp(16.0, double.infinity)),
        children: [
          _GroupStatePanel(
            icon: c.isOpen ? Icons.receipt_long_outlined : Icons.lock_outline,
            title: _groupStatusLabel(c.status),
            description: [
              if (c.purpose.trim().isNotEmpty) c.purpose,
              if (c.description.trim().isNotEmpty) c.description,
            ].join('\n').trim(),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            borderRadius: ProductTheme.selectionMenuRadius,
            elevation: ProductTheme.selectionMenuElevation,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            initialValue: _participation,
            isExpanded: true,
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
              helperMaxLines: 3,
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
            const SizedBox(height: 8),
            if (_loadingContributions)
              const Center(child: Text('Загружаем данные…'))
            else if (_contributionsError)
              _GroupStatePanel(
                icon: Icons.error_outline,
                title: 'Не удалось загрузить отметки участников',
                action: TextButton.icon(
                    onPressed: _loadContributions,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Повторить')),
              )
            else if (_contributions.isEmpty)
              const _GroupStatePanel(
                icon: Icons.people_outline,
                title: 'Отметок пока нет',
              )
            else
              _GroupRows(
                  children: _contributions.map((row) {
                final userId = row['user_id']?.toString() ?? '';
                final displayName =
                    (row['display_name']?.toString() ?? '').trim();
                final titleLabel =
                    displayName.isNotEmpty ? displayName : 'Участник';
                final payment = row['payment_status']?.toString() ?? 'unmarked';
                final proofUrl = row['proof_file_url']?.toString() ?? '';
                final hasProof = proofUrl.isNotEmpty ||
                    (row['proof_file_id']?.toString() ?? '').isNotEmpty;
                final canReview = payment != 'confirmed';
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(titleLabel),
                        subtitle: Text(
                          '${_paymentStatusLabel(payment)}'
                          '${hasProof ? ' · есть подтверждение' : ''}',
                        ),
                      ),
                      Align(
                          alignment: Alignment.centerRight,
                          child: Wrap(
                            spacing: 4,
                            children: [
                              if (proofUrl.isNotEmpty)
                                IconButton(
                                  tooltip: 'Открыть подтверждение',
                                  onPressed: () async {
                                    final uri = Uri.tryParse(
                                        await ChatFileAccess.resolve(proofUrl));
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
                          )),
                    ]);
              }).toList()),
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
    if (!mounted) return;
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
    final values = await showDialog<List<String>>(
        context: context,
        builder: (_) => const _GroupFieldsDialog(
                title: 'Добавить тему',
                action: 'Добавить',
                fields: [
                  _GroupField('Название темы', initial: '', numeric: false),
                  _GroupField('Количество мест', initial: '1', numeric: true),
                ]));
    if (!mounted || values == null) return;
    final title = values[0].trim();
    final capacity = int.tryParse(values[1].trim()) ?? 0;
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selection = widget.selection;
    final isOpen = selection.isOpen;
    final cancelled = selection.status == 'cancelled';
    final description = selection.description.trim();

    return Scaffold(
      appBar: AppBar(title: Text(selection.title)),
      body: _loading
          ? const Center(child: ProductLoadingIndicator.page())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(
                    vertical: 24,
                    horizontal: ((MediaQuery.sizeOf(context).width - 800) / 2)
                        .clamp(16.0, double.infinity)),
                children: [
                  if (_error != null) ...[
                    _GroupStatePanel(
                      icon: Icons.error_outline_rounded,
                      title: _error!,
                      action: TextButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить'),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _GroupStatePanel(
                    icon: isOpen
                        ? Icons.checklist_rounded
                        : cancelled
                            ? Icons.block_rounded
                            : Icons.lock_outline_rounded,
                    title: isOpen
                        ? 'Выбор открыт'
                        : _groupStatusLabel(selection.status),
                    description: _options.isEmpty
                        ? null
                        : isOpen
                            ? 'Выберите тему, в которой есть свободное место.'
                            : 'Варианты доступны для просмотра.',
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(description, style: theme.textTheme.bodyMedium),
                  ],
                  if (_options.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Варианты тем', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _GroupRows(
                      children: [
                        for (final option in _options)
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            leading: Icon(
                              _myPick == option.id
                                  ? Icons.check_circle_rounded
                                  : Icons.article_outlined,
                              color: _myPick == option.id
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                            title: Text(option.title,
                                style: theme.textTheme.titleSmall),
                            subtitle: Text([
                              if (_myPick == option.id) 'Ваш выбор',
                              isOpen
                                  ? 'Свободно ${option.freeSlots} из ${option.capacity}'
                                  : 'Занято ${option.taken} из ${option.capacity}',
                            ].join(' · ')),
                            trailing: isOpen && _myPick != option.id
                                ? TextButton(
                                    onPressed: option.isFull
                                        ? null
                                        : () => _pick(option),
                                    child: const Text('Выбрать'),
                                  )
                                : null,
                          ),
                      ],
                    ),
                  ] else if (_error == null) ...[
                    const SizedBox(height: 16),
                    const _GroupStatePanel(
                      icon: Icons.article_outlined,
                      title: 'Темы пока не добавлены',
                    ),
                  ],
                  const SizedBox(height: 12),
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

class _GroupStatePanel extends StatelessWidget {
  const _GroupStatePanel({
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.primary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  if (description != null && description!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(description!,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant)),
                  ],
                  if (action != null) action!,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _groupStatusLabel(String status) => switch (status) {
      'open' => 'Открыто',
      'closed' => 'Завершено',
      'cancelled' => 'Отменено',
      'draft' => 'Черновик',
      _ => status,
    };

class _GroupField {
  const _GroupField(this.label, {this.initial = '', this.numeric = false});
  final String label;
  final String initial;
  final bool numeric;
}

class _GroupFieldsDialog extends StatefulWidget {
  const _GroupFieldsDialog(
      {required this.title, required this.action, required this.fields});
  final String title;
  final String action;
  final List<_GroupField> fields;
  @override
  State<_GroupFieldsDialog> createState() => _GroupFieldsDialogState();
}

class _GroupFieldsDialogState extends State<_GroupFieldsDialog> {
  late final controllers = widget.fields
      .map((field) => TextEditingController(text: field.initial))
      .toList();
  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(widget.title),
        content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < widget.fields.length; i++)
                Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: TextField(
                      controller: controllers[i],
                      keyboardType: widget.fields[i].numeric
                          ? TextInputType.number
                          : TextInputType.text,
                      decoration:
                          InputDecoration(labelText: widget.fields[i].label),
                    )),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context,
                  controllers.map((controller) => controller.text).toList()),
              child: Text(widget.action)),
        ],
      );
}
