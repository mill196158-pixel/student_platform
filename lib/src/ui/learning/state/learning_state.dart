import '../models/team.dart';

enum ViewMode { list, grid }

class LearningState {
  final bool loading;
  final List<Team> teams;
  final Set<String> hiddenIds; // скрытые
  final bool manageMode;       // оставил на будущее (не используется)
  final ViewMode viewMode;     // список / плитка

  const LearningState({
    this.loading = false,
    this.teams = const [],
    this.hiddenIds = const {},
    this.manageMode = false,
    this.viewMode = ViewMode.list,
  });

  LearningState copyWith({
    bool? loading,
    List<Team>? teams,
    Set<String>? hiddenIds,
    bool? manageMode,
    ViewMode? viewMode,
  }) =>
      LearningState(
        loading: loading ?? this.loading,
        teams: teams ?? this.teams,
        hiddenIds: hiddenIds ?? this.hiddenIds,
        manageMode: manageMode ?? this.manageMode,
        viewMode: viewMode ?? this.viewMode,
      );
}
