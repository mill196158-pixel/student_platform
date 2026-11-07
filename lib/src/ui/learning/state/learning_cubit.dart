// lib/src/ui/learning/state/learning_cubit.dart
import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:student_platform/src/ui/learning/data/confirmed_team_catalog.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/ui/learning/state/scoped_team_catalog.dart';

import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/state/learning_state.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';

class LearningCubit extends Cubit<LearningState> {
  final LearningRepository repo;
  final ScopedTeamCatalogStore? catalogStore;
  final SessionCapabilities? catalogCapabilities;
  final OnlineSideEffectBarrier? catalogBarrier;
  @visibleForTesting
  final Future<List<Team>> Function()? debugConfirmedCatalog;

  LearningCubit({LearningRepository? repository, this.catalogStore, this.catalogCapabilities, this.catalogBarrier, this.debugConfirmedCatalog})
      : repo = repository ?? SupabaseLearningRepository(),
        super(const LearningState());

  Future<void> load(String groupCode) async {
    unawaited(_saveConfirmedCatalog());
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

  Future<void> _saveConfirmedCatalog() async {
    final store = catalogStore, caps = catalogCapabilities, source = repo, barrier = catalogBarrier;
    final debugFetch = debugConfirmedCatalog;
    if (store == null || caps == null || barrier == null ||
        (debugFetch == null && source is! SupabaseLearningRepository) || isClosed) return;
    try {
      await barrier.run(() async {
        bool sourceCurrent() => !isClosed && barrier.isOpen && caps.mode == SessionCapabilityMode.online;
        final ticket = await store.begin(caps, sourceCurrent: sourceCurrent);
        if (ticket == null) return;
        bool current() => sourceCurrent() && caps.permits(ticket.permit, SessionCapability.networkRead);
        if (!current()) return;
        List<Team> teams;
        try {
          teams = debugFetch != null ? await debugFetch()
              : await (source as SupabaseLearningRepository).loadConfirmedOfflineCatalog(current: current);
        } catch (error) {
          if (isConfirmedCatalogDenial(error) && store.scope.isCurrent(ticket.owner)) {
            await store.deny(ticket);
          }
          return;
        }
        if (!current()) return;
        await store.commit(ticket, caps, teams, DateTime.now());
      });
    } catch (_) {
      // Retain the last confirmed snapshot; no legacy fallback is promoted.
    }
  }

  List<Team> get visibleTeams =>
      state.teams.where((t) => !state.hiddenIds.contains(t.id)).toList();

  /// Permanent group chat card for Learning (not a subject tile).
  Team? get groupSpaceTeam {
    for (final team in visibleTeams) {
      if (team.isGroupSpaceChat) return team;
    }
    return null;
  }

  /// Subject teams only — group_space is shown via [groupSpaceTeam].
  List<Team> get subjectTeams =>
      visibleTeams.where((t) => !t.isGroupSpaceChat).toList();

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
    final next =
        state.viewMode == ViewMode.list ? ViewMode.grid : ViewMode.list;
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
