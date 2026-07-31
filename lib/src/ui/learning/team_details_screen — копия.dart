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

class _Body extends StatefulWidget {
  const _Body({super.key});

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 1);
    _tabController.addListener(() {
      // Прячем клавиатуру при смене вкладок (тап/свайп)
      FocusScope.of(context).unfocus();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TeamCubit>();
    final team = cubit.state.team;

    return Scaffold(
      appBar: _selecting
          ? null
          : AppBar(
              title: Text(team.name),
              bottom: TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: 'Задания'),
                  Tab(text: 'Чат'),
                  Tab(text: 'Файлы'),
                ],
              ),
              actions: const [AssignmentsViewModeButton()],
            ),
      body: TabBarView(
        controller: _tabController,
        children: [
          AssignmentsTab(team: team),
          ChatTab(onSelectingChanged: (v) => setState(() => _selecting = v)),
          const FilesTab(),
        ],
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
