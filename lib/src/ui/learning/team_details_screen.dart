import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'models/team.dart';
import 'state/team_cubit.dart';
import 'tabs/assignments_tab.dart';
import 'tabs/chat_tab.dart';
import 'tabs/files_tab.dart';
import 'tabs/assignments/view_mode.dart';

class TeamDetailsScreen extends StatelessWidget {
  final Team team;
  const TeamDetailsScreen({super.key, required this.team});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<TeamCubit>(
      create: (_) {
        final c = TeamCubit(team);
        c.init();
        return c;
      },
      child: const _Body(),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TeamCubit>();
    final team = cubit.state.team;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(team.name),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Задания'),
              Tab(text: 'Чат'),
              Tab(text: 'Файлы'),
            ],
          ),
          actions: const [AssignmentsViewModeButton()],
        ),
        // ВАЖНО: убираем const, чтобы передать team
        body: TabBarView(
          children: [
            AssignmentsTab(team: team), // берём из TeamCubit
            const ChatTab(),
            const FilesTab(),
          ],
        ),
      ),
    );
  }
}

class AssignmentsViewModeButton extends StatelessWidget {
  const AssignmentsViewModeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AssignmentsViewMode.grid,
      builder: (_, asGrid, __) => IconButton(
        tooltip: asGrid ? 'Показать списком' : 'Показать сеткой',
        icon: Icon(asGrid ? Icons.view_list : Icons.grid_view_rounded),
        onPressed: () => AssignmentsViewMode.grid.value = !asGrid,
      ),
    );
  }
}
