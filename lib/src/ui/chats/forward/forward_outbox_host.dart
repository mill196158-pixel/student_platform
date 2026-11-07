import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../../core/auth_session_scope.dart';
import '../../../core/auth_session_scope_host.dart';
import '../../../config/supabase_config.dart';
import 'durable_forward_outbox.dart';
import 'forward_outbox_preferences.dart';
import 'forward_outbox_store.dart';

/// Passive owner: it never reads or removes an outbox entry by itself.
class ForwardOutboxHost extends StatefulWidget {
  const ForwardOutboxHost(
      {super.key,
      required this.child,
      this.source,
      this.storage,
      this.openDatabaseOverride,
      this.backendOverride,
      this.durableMode = false});
  final Widget child;

  /// Switched on only after every forward consumer uses the durable pipeline.
  final bool durableMode;
  @visibleForTesting
  final AuthSessionScope? source;
  @visibleForTesting
  final ForwardOutboxStorage? storage;
  @visibleForTesting
  final Future<Database> Function()? openDatabaseOverride;
  @visibleForTesting
  final String? backendOverride;

  /// Isolated Android QA only. Production and all other platforms retain
  /// their current mode unless a separate migration is reviewed.
  static bool get androidQaMode => androidQaModeFor(
      enabled: const bool.fromEnvironment('FORWARD_DURABLE_ANDROID_QA'),
      web: kIsWeb,
      platform: defaultTargetPlatform);

  @visibleForTesting
  static bool androidQaModeFor(
          {required bool enabled,
          required bool web,
          required TargetPlatform platform}) =>
      enabled && !web && platform == TargetPlatform.android;

  static ForwardOutboxStore? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ForwardOutboxProvider>()?.store;

  static bool usesDurable(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<_ForwardOutboxProvider>()
          ?.durableMode ??
      false;

  static Future<DurableForwardOutbox> durable(BuildContext context) {
    final provider =
        context.getInheritedWidgetOfExactType<_ForwardOutboxProvider>();
    if (provider == null) throw StateError('Forward outbox unavailable');
    return provider.openDurable();
  }

  /// The persistent forward pipeline is supported on the mobile clients.
  /// Other platforms retain their existing mode until their storage is tested.
  static bool get mobileProductionMode => mobileProductionModeFor(
      web: kIsWeb, platform: defaultTargetPlatform);

  @visibleForTesting
  static bool mobileProductionModeFor({required bool web, required TargetPlatform platform}) =>
      !web && (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

  @override
  State<ForwardOutboxHost> createState() => _ForwardOutboxHostState();
}

class _ForwardOutboxHostState extends State<ForwardOutboxHost> {
  static final _productionCoordinator =
      ForwardOutboxCoordinator(PreferencesForwardOutboxStorage());
  static final _testCoordinators = Expando<ForwardOutboxCoordinator>();
  late final ForwardOutboxCoordinator _coordinator;
  AuthSessionScope? _scope;
  ForwardOutboxStore? _store;
  Future<Database>? _database;

  Future<DurableForwardOutbox> _openDurable() async {
    if (kIsWeb && widget.openDatabaseOverride == null) {
      throw UnsupportedError('Durable forwards unavailable on web');
    }
    final scope = _scope;
    if (scope == null) throw StateError('Forward session unavailable');
    final db = await (_database ??= widget.openDatabaseOverride?.call() ??
        () async {
          final dir = await getDatabasesPath();
          return openDurableForwardDatabase(
              path.join(dir, 'forward_outbox_v1.db'));
        }());
    if (!mounted || !identical(scope, _scope))
      throw StateError('Session changed');
    return DurableForwardOutbox(
        db, scope, widget.backendOverride ?? SupabaseConfig.url);
  }

  @override
  void initState() {
    super.initState();
    if ((widget.openDatabaseOverride != null ||
            widget.backendOverride != null) &&
        (widget.openDatabaseOverride == null ||
            widget.backendOverride == null ||
            widget.source == null ||
            widget.storage == null)) {
      throw ArgumentError(
          'Test overrides require an isolated scope, storage, database and backend');
    }
    final storage = widget.storage;
    _coordinator = storage == null
        ? _productionCoordinator
        : (_testCoordinators[storage] ??= ForwardOutboxCoordinator(storage));
    _coordinator.bindMode(widget.durableMode);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant ForwardOutboxHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.source, oldWidget.source)) _bind();
    assert(identical(widget.storage, oldWidget.storage),
        'ForwardOutboxHost storage must remain stable for its lifetime');
    if (widget.durableMode != oldWidget.durableMode) {
      throw StateError(
          'Forward outbox mode must remain stable for its lifetime');
    }
    if (!identical(
            widget.openDatabaseOverride, oldWidget.openDatabaseOverride) ||
        widget.backendOverride != oldWidget.backendOverride) {
      throw StateError(
          'Forward test overrides must remain stable for host lifetime');
    }
  }

  void _bind() {
    final source = widget.source ?? AuthSessionScopeHost.maybeOf(context);
    if (identical(source, _scope)) return;
    _scope?.removeListener(_clearAutoApprovals);
    _coordinator.clearAutoApprovals();
    _store?.dispose();
    _scope = source;
    _scope?.addListener(_clearAutoApprovals);
    _store = source == null ? null : ForwardOutboxStore(source, _coordinator);
  }

  void _clearAutoApprovals() => _coordinator.clearAutoApprovals();

  @override
  void dispose() {
    _scope?.removeListener(_clearAutoApprovals);
    _coordinator.clearAutoApprovals();
    _store?.dispose();
    _database?.then((db) => db.close()).ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return store == null
        ? widget.child
        : _ForwardOutboxProvider(
            store: store,
            openDurable: _openDurable,
            durableMode: widget.durableMode,
            child: widget.child);
  }
}

class _ForwardOutboxProvider extends InheritedWidget {
  const _ForwardOutboxProvider(
      {required this.store,
      required this.openDurable,
      required this.durableMode,
      required super.child});
  final ForwardOutboxStore store;
  final Future<DurableForwardOutbox> Function() openDurable;
  final bool durableMode;
  @override
  bool updateShouldNotify(_ForwardOutboxProvider oldWidget) =>
      !identical(store, oldWidget.store) ||
      durableMode != oldWidget.durableMode;
}
