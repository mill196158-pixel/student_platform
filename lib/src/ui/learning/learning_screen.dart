// =============================
// FILE: lib/src/ui/learning/learning_screen.dart
// =============================

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'state/learning_cubit.dart';
import 'state/learning_state.dart';
import 'team_details_screen.dart';
import 'models/team.dart';
import 'manage/manage_teams_screen.dart';

class LearningScreen extends StatelessWidget {
  const LearningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<LearningCubit>(
      create: (_) => LearningCubit()..load(getCurrentGroupCodeSync(context)),
      child: const _Body(),
    );
  }
}

/// Заглушка: берём текущую группу локально (потом свяжем с профилем)
String getCurrentGroupCodeSync(BuildContext context) => '1-См(ВВ)-1';

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  RealtimeChannel? _teamsMembershipChannel;

  @override
  void initState() {
    super.initState();
    _subscribeToTeamsRealtime();
  }

  void _subscribeToTeamsRealtime() {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;

    // Перестраховка: отписываем старый канал (если был)
    _teamsMembershipChannel?.unsubscribe();

    _teamsMembershipChannel = client.channel('public:team_members:$uid')

      // Добавили в команду
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'team_members',
        callback: (payload) {
          final row = payload.newRecord;
          if (row != null && row['user_id'] == uid) {
            context.read<LearningCubit>().load(getCurrentGroupCodeSync(context));
          }
        },
      )

      // Удалили из команды
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'team_members',
        callback: (payload) {
          final row = payload.oldRecord;
          if (row != null && row['user_id'] == uid) {
            context.read<LearningCubit>().load(getCurrentGroupCodeSync(context));
          }
        },
      )

      ..subscribe();
  }

  @override
  void dispose() {
    _teamsMembershipChannel?.unsubscribe();
    _teamsMembershipChannel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Команды'),
        centerTitle: true,
        // слева — переключатель список/плитка
        leading: BlocBuilder<LearningCubit, LearningState>(
          builder: (context, state) {
            final isGrid = state.viewMode == ViewMode.grid;
            return IconButton(
              tooltip: isGrid ? 'Список' : 'Плитка',
              icon: Icon(isGrid ? Icons.view_list : Icons.grid_view_rounded),
              onPressed: () => context.read<LearningCubit>().toggleViewMode(),
            );
          },
        ),
        actions: [
          // справа — переход в экран управления
          IconButton(
            tooltip: 'Управление командами',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              final cubit = context.read<LearningCubit>();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BlocProvider.value(
                    value: cubit,
                    child: ManageTeamsScreen(
                      groupCode: getCurrentGroupCodeSync(context),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: BlocBuilder<LearningCubit, LearningState>(
        builder: (context, state) {
          if (state.loading) {
            return const Center(child: CircularProgressIndicator());
          }

          final items = context.read<LearningCubit>().visibleTeams;

          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Пока нет команд для вашей группы',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      final cubit = context.read<LearningCubit>();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => BlocProvider.value(
                            value: cubit,
                            child: ManageTeamsScreen(
                              groupCode: getCurrentGroupCodeSync(context),
                            ),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Управление командами'),
                  ),
                ],
              ),
            );
          }

          // переключение макета
          if (state.viewMode == ViewMode.grid) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, // как иконки на телефоне
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.2,
                ),
                itemCount: items.length,
                itemBuilder: (_, i) => _TeamGridCard(items[i]),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _TeamTile(items[i]),
          );
        },
      ),
    );
  }
}

class _TeamTile extends StatelessWidget {
  final Team team;
  const _TeamTile(this.team);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TeamDetailsScreen(team: team)),
      ),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            _Avatar(text: team.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    team.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(team.teacher,
                      style: TextStyle(color: Colors.grey.shade400)),
                ],
              ),
            ),
            if (team.unread > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blueAccent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('${team.unread}',
                    style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }
}

class _TeamGridCard extends StatelessWidget {
  final Team team;
  const _TeamGridCard(this.team);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TeamDetailsScreen(team: team)),
      ),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(text: team.icon),
            const SizedBox(height: 10),
            Text(
              team.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              team.teacher,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String text;
  const _Avatar({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      width: 44,
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}
