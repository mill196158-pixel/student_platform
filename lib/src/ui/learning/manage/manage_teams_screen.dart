import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../common/friendly_empty_state.dart';
import '../state/learning_cubit.dart';
import '../state/learning_state.dart';
import '../widgets/team_avatar.dart';

class ManageTeamsScreen extends StatefulWidget {
  final String groupCode;
  const ManageTeamsScreen({super.key, required this.groupCode});
  @override
  State<ManageTeamsScreen> createState() => _ManageTeamsScreenState();
}

class _ManageTeamsScreenState extends State<ManageTeamsScreen> {
  final _search = TextEditingController();
  String _query = '';
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = await showDialog<String>(
        context: context, builder: (_) => const _InviteCodeDialog());
    if (!mounted || code == null || code.trim().isEmpty) return;
    try {
      await context
          .read<LearningCubit>()
          .joinByInviteCode(code.trim(), widget.groupCode);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Команда добавлена')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Управление командами'), actions: [
        IconButton(
            tooltip: 'Добавить по коду',
            onPressed: _join,
            icon: const Icon(Icons.add_rounded)),
      ]),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: BlocBuilder<LearningCubit, LearningState>(
                builder: (context, state) {
              final query = _query.trim().toLowerCase();
              final teams = state.teams
                  .where((team) =>
                      query.isEmpty ||
                      team.name.toLowerCase().contains(query) ||
                      team.teacher.toLowerCase().contains(query))
                  .toList();
              return Column(children: [
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _search,
                      decoration: InputDecoration(
                          hintText: 'Команда или преподаватель',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Очистить поиск',
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: () {
                                    _search.clear();
                                    setState(() => _query = '');
                                  })),
                      onChanged: (value) => setState(() => _query = value),
                    )),
                if (state.loading) const LinearProgressIndicator(),
                Expanded(
                    child: teams.isEmpty
                        ? Center(
                            child: SingleChildScrollView(
                                child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: state.loading
                                ? const ProductLoadingIndicator.page()
                                : FriendlyEmptyState(
                                    fallbackIcon: query.isEmpty
                                        ? Icons.groups_outlined
                                        : Icons.search_off_rounded,
                                    animationHeight: 72,
                                    title: query.isEmpty
                                        ? 'Команд пока нет'
                                        : 'Ничего не найдено',
                                    subtitle: query.isEmpty
                                        ? 'Добавьте команду по коду приглашения.'
                                        : 'Попробуйте другое название или имя преподавателя.'),
                          )))
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            itemCount: teams.length,
                            separatorBuilder: (_, __) => Divider(
                                height: 1,
                                color: theme.colorScheme.outlineVariant),
                            itemBuilder: (_, index) {
                              final team = teams[index];
                              return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        TeamAvatar(
                                            icon: team.icon,
                                            name: team.name,
                                            size: 40),
                                        const SizedBox(width: 14),
                                        Expanded(
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                              Text(team.name,
                                                  style: theme
                                                      .textTheme.titleSmall),
                                              if (team.teacher
                                                  .trim()
                                                  .isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(team.teacher,
                                                    style: theme
                                                        .textTheme.bodyMedium
                                                        ?.copyWith(
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant)),
                                              ],
                                            ])),
                                      ]));
                            })),
              ]);
            })),
      ),
    );
  }
}

class _InviteCodeDialog extends StatefulWidget {
  const _InviteCodeDialog();
  @override
  State<_InviteCodeDialog> createState() => _InviteCodeDialogState();
}

class _InviteCodeDialogState extends State<_InviteCodeDialog> {
  final _code = TextEditingController();
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _accept() {
    final code = _code.text.trim();
    if (code.isNotEmpty) Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('Добавить команду'),
        content: SizedBox(
            width: 400,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Введите код приглашения от организатора команды.'),
                  const SizedBox(height: 20),
                  TextField(
                      controller: _code,
                      autofocus: true,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      decoration:
                          const InputDecoration(labelText: 'Код приглашения'),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _accept()),
                ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: _code.text.trim().isEmpty ? null : _accept,
              child: const Text('Добавить')),
        ],
      );
}
