import 'package:flutter/widgets.dart';
import 'team_assignment_snapshot_store.dart';
import 'team_snapshot_preferences.dart';

/// Owns one coordinator; construction and rebuild perform no storage I/O.
class TeamSnapshotHost extends StatefulWidget {
  const TeamSnapshotHost({super.key, required this.child, this.storage});
  final Widget child;
  @visibleForTesting
  final TeamSnapshotStorage? storage;

  static TeamSnapshotCoordinator? maybeRead(BuildContext context) => context
      .getInheritedWidgetOfExactType<_TeamSnapshotProvider>()
      ?.coordinator;

  @override
  State<TeamSnapshotHost> createState() => _TeamSnapshotHostState();
}

class _TeamSnapshotHostState extends State<TeamSnapshotHost> {
  late final TeamSnapshotCoordinator _coordinator;
  @override
  void initState() {
    super.initState();
    _coordinator = TeamSnapshotCoordinator(
        widget.storage ?? PreferencesTeamSnapshotStorage());
  }

  @override
  void didUpdateWidget(covariant TeamSnapshotHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(identical(widget.storage, oldWidget.storage),
        'TeamSnapshotHost storage must remain stable');
  }

  @override
  Widget build(BuildContext context) =>
      _TeamSnapshotProvider(coordinator: _coordinator, child: widget.child);
}

class _TeamSnapshotProvider extends InheritedWidget {
  const _TeamSnapshotProvider(
      {required this.coordinator, required super.child});
  final TeamSnapshotCoordinator coordinator;
  @override
  bool updateShouldNotify(_TeamSnapshotProvider oldWidget) =>
      !identical(coordinator, oldWidget.coordinator);
}
