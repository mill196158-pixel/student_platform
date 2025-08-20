import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../state/team_cubit.dart';
import '../models/message.dart';
import '../models/assignment.dart';
import '../assignment_details_screen.dart';

// виджеты
import 'chat/composer.dart';
import 'chat/scroll_to_bottom_button.dart';
import 'chat/swipe_to_reply.dart';
import 'chat/message_bubble.dart';
import 'chat/assignment_bubble.dart';
import 'chat/plus_button.dart';
import 'chat/pinned_strip.dart';
import 'chat/typing_line.dart';

class ChatTab extends StatefulWidget {
  const ChatTab({super.key});
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, Map<String, int>> _localReactions = {};
  final Map<String, GlobalKey> _messageKeys = {};

  bool _showJump = false;

  Message? _replyTo;
  String? _pickedImage;

  final List<PinEntry> _pins = [];
  bool _pinsHidden = false;
  bool _autoPinHidden = false;

  final Set<String> _typingUsers = {};
  Timer? _myTypingOff;
  bool get _someoneTyping => _typingUsers.isNotEmpty;

  final FocusNode _composerFocus = FocusNode();

  static const double _assignmentScale = 0.70;      // −30%
  static const double _assignmentTextBoost = 1.18;  // +18%

  static const services.MethodChannel _keyboardChannel =
      services.MethodChannel('keyboard_image_channel');

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _ctrl.addListener(_onMyTyping);

    _keyboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onKeyboardImagePicked') {
        final path = (call.arguments ?? '') as String;
        if (path.isNotEmpty && mounted) {
          setState(() => _pickedImage = path);
        }
      }
      return null;
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _ctrl.removeListener(_onMyTyping);
    _scroll.dispose();
    _ctrl.dispose();
    _composerFocus.dispose();
    _myTypingOff?.cancel();
    super.dispose();
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.offset < _scroll.position.maxScrollExtent - 300;
    if (show != _showJump) setState(() => _showJump = show);
  }

  void _onMyTyping() {
    setState(() => _typingUsers.add('Вы'));
    _myTypingOff?.cancel();
    _myTypingOff = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _typingUsers.remove('Вы'));
    });
  }

  String _time(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _jumpToBottom() async {
    if (!_scroll.hasClients) return;
    await _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _scrollToMessage(String id) async {
    final ctx = _messageKeys[id]?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        alignment: .2,
        curve: Curves.easeOut,
      );
    }
  }

  List<PinEntry> _buildPins(TeamState st) {
    final manual = [..._pins];
    if (!_autoPinHidden) {
      final pending = st.pending;
      final published = st.published.isNotEmpty ? st.published.last : null;
      final a = pending ?? published;
      final alreadyHasManual = a != null && manual.any((p) => p.type == PinType.assignment && p.refId == a.id);
      if (a != null && !alreadyHasManual) {
        manual.insert(
          0,
          PinEntry.assignment(
            id: 'auto-${a.id}',
            title: a.title,
            subtitle: a.due != null ? 'до ${a.due}' : null,
            assignmentId: a.id,
            isAuto: true,
          ),
        );
      }
    }
    return manual;
  }

  void _pinFromMessage(Message m) {
    if (m.text.trim().isEmpty) return;
    if (_pins.any((p) => p.type == PinType.message && p.refId == m.id)) return;
    setState(() {
      _pins.add(PinEntry.message(
        id: 'msg-${m.id}',
        title: m.text.trim().split('\n').first,
        subtitle: null,
        messageId: m.id,
      ));
      _pinsHidden = false;
    });
  }

  void _pinText(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    setState(() {
      _pins.add(PinEntry.text(
        id: 'txt-${DateTime.now().microsecondsSinceEpoch}',
        title: t,
      ));
      _pinsHidden = false;
    });
  }

  void _pinAssignment(Assignment a) {
    if (_pins.any((p) => p.type == PinType.assignment && p.refId == a.id && !p.isAuto)) return;
    setState(() {
      _pins.add(PinEntry.assignment(
        id: 'ass-${a.id}',
        title: a.title,
        subtitle: a.due != null ? 'до ${a.due}' : null,
        assignmentId: a.id,
      ));
      _pinsHidden = false;
    });
  }

  void _addReaction(String msgId, String emoji) {
    setState(() {
      final map = _localReactions[msgId] ?? <String, int>{};
      map[emoji] = (map[emoji] ?? 0) + 1;
      _localReactions[msgId] = map;
    });
  }

  void _send(BuildContext context) {
    final text = _ctrl.text.trim();
    if (text.isEmpty && _pickedImage == null) return;

    final replyId = _replyTo?.id;
    _ctrl.clear();
    setState(() => _replyTo = null);

    context.read<TeamCubit>().sendMessage(
      'me',
      text,
      imagePath: _pickedImage,
      replyToId: replyId,
    );
    setState(() => _pickedImage = null);

    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final scale = mq.textScaleFactor.clamp(1.0, 1.2);
    final themed = Theme.of(context);

    const listBottomPad = 96.0;

    return MediaQuery(
      data: mq.copyWith(textScaleFactor: scale),
      child: BlocBuilder<TeamCubit, TeamState>(
        builder: (context, state) {
          final list = state.chat;
          final pins = _buildPins(state);

          return Column(
            children: [
              if (!_pinsHidden && pins.isNotEmpty)
                PinnedStrip(
                  entries: pins,
                  onOpen: (p) async {
                    switch (p.type) {
                      case PinType.message:
                        await _scrollToMessage(p.refId!);
                        break;
                      case PinType.assignment:
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<TeamCubit>(),
                              child: AssignmentDetailsScreen(assignmentId: p.refId!),
                            ),
                          ),
                        );
                        break;
                      case PinType.text:
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(p.title)));
                        break;
                    }
                  },
                  onUnpin: (p) {
                    if (p.isAuto) {
                      setState(() => _autoPinHidden = true);
                    } else {
                      setState(() => _pins.removeWhere((e) => e.id == p.id));
                    }
                  },
                  onMore: () async {
                    await showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      builder: (_) => SafeArea(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.visibility_off_outlined),
                              title: const Text('Скрыть ленту'),
                              onTap: () {
                                Navigator.pop(context);
                                setState(() => _pinsHidden = true);
                              },
                            ),
                            if (!_autoPinHidden)
                              ListTile(
                                leading: const Icon(Icons.push_pin_outlined),
                                title: const Text('Убрать авто-закреп задания'),
                                onTap: () {
                                  Navigator.pop(context);
                                  setState(() => _autoPinHidden = true);
                                },
                              ),
                            if (_pins.isNotEmpty) const Divider(height: 12),
                            ..._pins.map((p) => ListTile(
                                  leading: Icon(p.icon),
                                  title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: p.subtitle != null ? Text(p.subtitle!) : null,
                                  trailing: IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () => setState(() => _pins.removeWhere((e) => e.id == p.id)),
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    if (p.type == PinType.message) _scrollToMessage(p.refId!);
                                    if (p.type == PinType.assignment) {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => BlocProvider.value(
                                            value: context.read<TeamCubit>(),
                                            child: AssignmentDetailsScreen(assignmentId: p.refId!),
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                )),
                          ],
                        ),
                      ),
                    );
                  },
                ),

              Expanded(
                child: Stack(
                  children: [
                    ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, listBottomPad),
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final m = list[i];
                        final key = _messageKeys[m.id] ??= GlobalKey();

                        if (m.type == MessageType.assignmentDraft || m.type == MessageType.assignmentPublished) {
                          final boostedTs = (mq.textScaleFactor * _assignmentTextBoost).clamp(1.0, 1.6);
                          return KeyedSubtree(
                            key: key,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Transform.scale(
                                scale: _assignmentScale,
                                alignment: Alignment.centerLeft,
                                child: MediaQuery(
                                  data: mq.copyWith(textScaleFactor: boostedTs),
                                  child: AssignmentBubble(
                                    message: m,
                                    isDraft: m.type == MessageType.assignmentDraft,
                                    time: _time(m.at),
                                    onOpen: () {
                                      final st = context.read<TeamCubit>().state;
                                      Assignment? a;
                                      final byId = st.assignments.where((e) => e.id == m.assignmentId);
                                      if (byId.isNotEmpty) a = byId.first; else if (st.published.isNotEmpty) a = st.published.last;
                                      if (a == null) return;
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => BlocProvider.value(
                                            value: context.read<TeamCubit>(),
                                            child: AssignmentDetailsScreen(assignmentId: a!.id),
                                          ),
                                        ),
                                      );
                                    },
                                    onPublish: () => context.read<TeamCubit>().publishPendingManually(),
                                    onVote: () => context.read<TeamCubit>().voteForPending(),
                                    onLongPress: () => _showAssignmentActions(context, m),
                                    onPin: () {
                                      final st = context.read<TeamCubit>().state;
                                      final a = st.assignments.firstWhere(
                                        (e) => e.id == m.assignmentId,
                                        orElse: () => st.published.isNotEmpty ? st.published.last : st.assignments.first,
                                      );
                                      _pinAssignment(a);
                                    },
                                  ),
                                ),
                              ),
                            ),
                          );
                        }

                        final reply = m.replyToId != null
                            ? state.chat.firstWhere(
                                (x) => x.id == m.replyToId,
                                orElse: () => Message(
                                  id: '0',
                                  chatId: '',
                                  authorId: '',
                                  authorLogin: '',
                                  authorName: '',
                                  text: '',
                                  at: DateTime.now(),
                                ),
                              )
                            : null;

                        return KeyedSubtree(
                          key: key,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SwipeToReply(
                              onReply: () => setState(() => _replyTo = m),
                              child: MessageBubble(
                                message: m,
                                time: _time(m.at),
                                replyPreview: reply?.text,
                                imagePath: m.imagePath,
                                reactions: _localReactions[m.id],
                                onReact: (emoji) => _addReaction(m.id, emoji),
                                onLongPress: () => _showMessageActions(context, m),
                              ),
                            ),
                          ),
                        );
                      },
                    ),

                    if (_showJump)
                      Positioned(
                        right: 12,
                        bottom: 82,
                        child: ScrollToBottomButton(onTap: _jumpToBottom),
                      ),
                  ],
                ),
              ),

              if (_replyTo != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: themed.colorScheme.surface.withOpacity(.6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: themed.colorScheme.outline.withOpacity(.25)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.reply, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_replyTo!.text, maxLines: 2, overflow: TextOverflow.ellipsis)),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _replyTo = null)),
                    ],
                  ),
                ),

              if (_someoneTyping) TypingLine(names: _typingUsers.toList()),

              Composer(
                controller: _ctrl,
                focusNode: _composerFocus,
                pickedImagePath: _pickedImage,
                leftButton: PlusButton(
                  onPinText: _pinText,
                  onPropose: (title, description, link, due, attachments) async {
                    await context.read<TeamCubit>().proposeAssignment(
                      title: title, description: description, link: link, due: due, attachments: attachments,
                    );
                  },
                ),
                onPickImage: () async {
                  final res = await ImagePicker().pickImage(source: ImageSource.gallery);
                  if (res != null) setState(() => _pickedImage = res.path);
                },
                onClearPicked: () => setState(() => _pickedImage = null),
                onOpenEmoji: () {
                  _composerFocus.requestFocus();
                  services.SystemChannels.textInput.invokeMethod('TextInput.show');
                },
                onSend: () => _send(context),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showMessageActions(BuildContext context, Message m) {
    final myUid = Supabase.instance.client.auth.currentUser?.id;

    const quick = ['❤️', '😂', '👍', '🔥', '👏', '🙏'];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Wrap(
                spacing: 10,
                children: quick
                    .map((e) => GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            _addReaction(m.id, e);
                          },
                          child: const Text('🙂', style: TextStyle(fontSize: 0)), // spacer to keep height
                        ))
                    .toList(),
              ),
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Ответить'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _replyTo = m);
              },
            ),
            if (m.text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_all_outlined),
                title: const Text('Копировать текст'),
                onTap: () {
                  Navigator.pop(context);
                  services.Clipboard.setData(services.ClipboardData(text: m.text));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
                },
              ),
            if (m.text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('Закрепить'),
                onTap: () {
                  Navigator.pop(context);
                  _pinFromMessage(m);
                },
              ),
            if (m.isMine(myUid) && DateTime.now().difference(m.at) <= const Duration(hours: 2))
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Удалить сообщение'),
                onTap: () async {
                  Navigator.pop(context);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Удалить сообщение?'),
                      content: const Text('Можно удалить в течение 2 часов после отправки.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    context.read<TeamCubit>().removeMessage(m.id);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showAssignmentActions(BuildContext context, Message m) async {
    final st = context.read<TeamCubit>().state;
    final a = st.assignments.firstWhere(
      (e) => e.id == m.assignmentId,
      orElse: () => st.published.isNotEmpty ? st.published.last : st.assignments.first,
    );

    final canEdit = st.isStarosta || true; // тут можно дополнить реальную проверку прав

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Закрепить'),
              onTap: () {
                Navigator.pop(context);
                _pinAssignment(a);
              },
            ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Редактировать задание'),
                onTap: () async {
                  Navigator.pop(context);
                  final res = await _editAssignmentDialog(context, a);
                  if (res == null) return;
                  await context.read<TeamCubit>().updateAssignment(
                        a.id,
                        title: res.$1,
                        description: res.$2,
                        link: res.$3,
                        due: res.$4,
                        attachments: res.$5,
                      );
                },
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Удалить задание'),
                onTap: () async {
                  Navigator.pop(context);
                  await context.read<TeamCubit>().removeAssignment(a.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<(String, String, String?, String?, List<Map<String, String>>)?> _editAssignmentDialog(
      BuildContext context, Assignment a) async {
    final title = TextEditingController(text: a.title);
    final desc  = TextEditingController(text: a.description);
    final link  = TextEditingController(text: a.link ?? '');
    final due   = TextEditingController(text: a.due ?? '');
    final files = [...a.attachments];

    return showDialog<(String, String, String?, String?, List<Map<String, String>>)>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Center(child: Text('Редактировать задание', style: TextStyle(fontWeight: FontWeight.w700))),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Название')),
                const SizedBox(height: 8),
                TextField(
                  controller: desc, minLines: 3, maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Что сделать'),
                ),
                const SizedBox(height: 8),
                TextField(controller: link, decoration: const InputDecoration(labelText: 'Ссылка (опц.)')),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      firstDate: now,
                      lastDate: now.add(const Duration(days: 365)),
                      initialDate: now,
                    );
                    if (picked != null) {
                      due.text = '${picked.day.toString().padLeft(2, '0')}.${picked.month.toString().padLeft(2, '0')}';
                      setState(() {});
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Срок'),
                    child: Align(alignment: Alignment.centerLeft, child: Text(due.text.isEmpty ? 'Не выбрано' : due.text)),
                  ),
                ),
                const SizedBox(height: 8),
                for (final f in files)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(f['name'] ?? ''),
                    subtitle: Text(f['path'] ?? ''),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty || desc.text.trim().isEmpty) return;
                Navigator.pop(context, (
                  title.text.trim(),
                  desc.text.trim(),
                  link.text.trim().isEmpty ? null : link.text.trim(),
                  due.text.trim().isEmpty ? null : due.text.trim(),
                  files
                ));
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }
}