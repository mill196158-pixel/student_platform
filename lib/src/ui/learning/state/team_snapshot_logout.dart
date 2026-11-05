import 'team_assignment_snapshot_store.dart';

/// Fence before awaiting logout; timeout does not cancel the underlying clear.
Future<bool> beginTeamSnapshotLogout({
  required TeamSnapshotCoordinator? coordinator,
  required String project,
  required String? userId,
  Duration timeout = const Duration(seconds: 2),
}) {
  if (coordinator == null || userId == null || userId.isEmpty) {
    return Future.value(true);
  }
  try {
    return coordinator
        .beginClear(project, userId)
        .then<bool>(
          (result) => result.complete,
          onError: (Object _, StackTrace __) => false,
        )
        .timeout(timeout, onTimeout: () => false);
  } catch (_) {
    return Future.value(false);
  }
}
