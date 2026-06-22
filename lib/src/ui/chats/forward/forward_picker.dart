// FILE: lib/src/ui/chats/forward/forward_picker.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/i_chat_service.dart';
import '../direct_chat_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';

class ForwardTarget {
  final String chatId;
  final String title;
  final String? avatarUrl;
  final ChatMode mode;
  final Future<void> Function(BuildContext) open;

  ForwardTarget({
    required this.chatId,
    required this.title,
    required this.mode,
    this.avatarUrl,
    required this.open,
  });
}

class ForwardPickerSheet extends StatefulWidget {
  const ForwardPickerSheet({super.key, required this.service});
  final IChatService service;

  @override
  State<ForwardPickerSheet> createState() => _ForwardPickerSheetState();
}

class _ForwardPickerSheetState extends State<ForwardPickerSheet> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  String _query = '';
  List<ForwardTarget> _all = [];
  List<ForwardTarget> _visible = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Пример: соберём первые DM и Teams (подправьте под свои вьюхи/RPC).
      final dmRows = await _sb.from('users').select('id, name, surname, avatar_url').limit(50);
      final dms = (dmRows as List)
          .cast<Map<String, dynamic>>()
          .map((r) {
            final peerId = r['id'] as String;
            final title = '${r['name'] ?? ''} ${r['surname'] ?? ''}'.trim();
            final avatar = r['avatar_url'] as String?;
            return ForwardTarget(
              chatId: 'dm_$peerId', // will be resolved to real chat id on confirm
              title: title.isEmpty ? 'Профиль' : title,
              avatarUrl: avatar,
              mode: ChatMode.dm,
              open: (ctx) async {
                await Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => BlocProvider.value(
                    value: ctx.read<TeamCubit>(),
                    child: DirectChatScreen(
                      peerId: peerId,
                      peerName: title.isEmpty ? 'Профиль' : title,
                      peerAvatarUrl: avatar,
                    ),
                  ),
                ));
              },
            );
          })
          .toList();

      final teamRows = await _sb.from('teams').select('id, title, logo_url').limit(50);
      final teams = (teamRows as List)
          .cast<Map<String, dynamic>>()
          .map((r) {
            final teamId = r['id'] as String;
            final title = (r['title'] ?? 'Команда') as String;
            final logo = r['logo_url'] as String?;
            return ForwardTarget(
              chatId: 'team_$teamId',
              title: title,
              avatarUrl: logo,
              mode: ChatMode.team,
              open: (ctx) async {
                final team = Team(
                  id: teamId,
                  name: title,
                  teacher: '',
                  groupCode: '',
                  icon: (logo ?? 'T'),
                );
                await Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => TeamDetailsScreen(team: team, initialTabIndex: 1),
                ));
              },
            );
          })
          .toList();

      _all = [...dms, ...teams];
      _applyFilter();
    } catch (e) {
      _all = [];
      _visible = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    if (_query.isEmpty) {
      _visible = List.of(_all);
    } else {
      final q = _query.toLowerCase();
      _visible = _all.where((t) => t.title.toLowerCase().contains(q)).toList();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Переслать в…'),
            centerTitle: true,
            automaticallyImplyLeading: false,
            leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: TextField(
                  onChanged: (s) { _query = s; _applyFilter(); },
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Поиск чата',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.separated(
                        padding: EdgeInsets.only(
                          left: 8, right: 8, bottom: MediaQuery.of(context).padding.bottom + 12,
                        ),
                        itemCount: _visible.length,
                        separatorBuilder: (_, __) => const Divider(indent: 72, height: 1),
                        itemBuilder: (_, i) {
                          final t = _visible[i];
                          return ListTile(
                            onTap: () => Navigator.pop(context, t),
                            leading: CircleAvatar(
                              radius: 22,
                              backgroundImage: (t.avatarUrl != null && t.avatarUrl!.isNotEmpty)
                                  ? CachedNetworkImageProvider(t.avatarUrl!) : null,
                              child: (t.avatarUrl == null || t.avatarUrl!.isEmpty)
                                  ? Icon(t.mode == ChatMode.dm ? Icons.person : Icons.groups)
                                  : null,
                            ),
                            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: const Icon(Icons.chevron_right),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
