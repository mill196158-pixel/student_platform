import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of `admin_bootstrap_demo_content`.
class DemoContentBootstrapResult {
  const DemoContentBootstrapResult({
    required this.dryRun,
    required this.entries,
    this.notificationsSuppressed = true,
    this.notes = const [],
  });

  final bool dryRun;
  final List<DemoContentBootstrapEntry> entries;
  final bool notificationsSuppressed;
  final List<String> notes;

  int get createCount => entries.where((e) => e.action == 'create').length;
  int get updateCount => entries.where((e) => e.action == 'update').length;
  int get conflictCount => entries.where((e) => e.action == 'conflict').length;
  int get skipCount => entries
      .where(
        (e) => e.action == 'skip_existing' || e.action == 'skip_tombstoned',
      )
      .length;

  static DemoContentBootstrapResult? tryParse(Object? raw) {
    dynamic value = raw;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    final entriesRaw = map['entries'];
    final entries = <DemoContentBootstrapEntry>[];
    if (entriesRaw is List) {
      for (final item in entriesRaw.whereType<Map>()) {
        final entry = DemoContentBootstrapEntry.tryParse(
          Map<String, dynamic>.from(item),
        );
        if (entry != null) entries.add(entry);
      }
    }
    final notesRaw = map['notes'];
    return DemoContentBootstrapResult(
      dryRun: map['dry_run'] == true,
      entries: entries,
      notificationsSuppressed: map['notifications_suppressed'] != false,
      notes: notesRaw is List
          ? notesRaw.map((e) => e.toString()).toList()
          : const [],
    );
  }
}

class DemoContentBootstrapEntry {
  const DemoContentBootstrapEntry({
    required this.resource,
    required this.legacyKey,
    required this.action,
    this.detail,
  });

  final String resource;
  final String legacyKey;
  final String action;
  final String? detail;

  static DemoContentBootstrapEntry? tryParse(Map<String, dynamic> json) {
    final legacyKey = json['legacy_key']?.toString();
    final action = json['action']?.toString();
    if (legacyKey == null || action == null) return null;
    return DemoContentBootstrapEntry(
      resource: (json['resource'] ?? '').toString(),
      legacyKey: legacyKey,
      action: action,
      detail: json['detail']?.toString(),
    );
  }
}

/// Real Admin only — never called from Local/Demo repositories.
class SupabaseDemoContentBootstrap {
  SupabaseDemoContentBootstrap({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _sb => _client ?? Supabase.instance.client;

  Future<DemoContentBootstrapResult> run({required bool dryRun}) async {
    final data = await _sb.rpc(
      'admin_bootstrap_demo_content',
      params: {'p_dry_run': dryRun},
    );
    final parsed = DemoContentBootstrapResult.tryParse(data);
    if (parsed == null) {
      throw StateError('Некорректный ответ bootstrap.');
    }
    return parsed;
  }
}
