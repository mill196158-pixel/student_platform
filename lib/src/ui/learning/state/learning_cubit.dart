// lib/src/ui/learning/state/learning_cubit.dart
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/state/learning_state.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';

class LearningCubit extends Cubit<LearningState> {
  final LearningRepository repo;

  LearningCubit({LearningRepository? repository})
      : repo = repository ?? SupabaseLearningRepository(),
        super(const LearningState());

  Future<void> load(String groupCode) async {
    emit(state.copyWith(loading: true));
    try {
      final teams = await repo.loadTeams(groupCode);
      final hidden = await repo.loadHiddenTeamIds();
      final modeStr = await repo.loadViewMode();
      final viewMode = modeStr == 'grid' ? ViewMode.grid : ViewMode.list;

      emit(state.copyWith(
        teams: teams,
        hiddenIds: hidden,
        viewMode: viewMode,
      ));
    } finally {
      // снимаем спиннер в любом случае
      emit(state.copyWith(loading: false));
    }
  }

  List<Team> get visibleTeams =>
      state.teams.where((t) => !state.hiddenIds.contains(t.id)).toList();

  Future<void> toggleHidden(String teamId) async {
    final set = {...state.hiddenIds};
    if (set.contains(teamId)) {
      set.remove(teamId);
    } else {
      set.add(teamId);
    }
    await repo.saveHiddenTeamIds(set);
    emit(state.copyWith(hiddenIds: set));
  }

  Future<void> toggleViewMode() async {
    final next = state.viewMode == ViewMode.list ? ViewMode.grid : ViewMode.list;
    await repo.saveViewMode(next == ViewMode.grid ? 'grid' : 'list');
    emit(state.copyWith(viewMode: next));
  }

  /// Добавление в команду по инвайт-коду → серверный RPC
  Future<void> addTeamByCode(String code, String groupCode) async {
    emit(state.copyWith(loading: true));
    try {
      await repo.joinByInviteCode(code.trim());
      final teams = await repo.loadTeams(groupCode);
      emit(state.copyWith(teams: teams));
    } finally {
      emit(state.copyWith(loading: false));
    }
  }

  /// ⚠️ Совместимость со старым вызовом из UI:
  /// ManageTeamsScreen вызывает joinByInviteCode(...),
  /// оставляем алиас, чтобы ничего в экране не менять.
  Future<void> joinByInviteCode(String code, String groupCode) {
    return addTeamByCode(code, groupCode);
  }
}
