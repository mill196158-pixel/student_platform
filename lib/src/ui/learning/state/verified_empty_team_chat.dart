import 'dart:collection';

import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'team_cache_owner.dart';

typedef _Key = (AuthSessionScope, int, String, String);

class _Entry {
  _Entry(this.token, this.ticket, this.chatId);
  final Object token;
  final AuthOperationScope? ticket;
  final String? chatId;
}

class EmptyTeamChatAttempt {
  EmptyTeamChatAttempt._(this._key, this._token, this._owner, this._ownerTicket,
      this._sessionTicket);
  final _Key _key;
  final Object _token;
  final TeamCacheOwner _owner;
  final TeamCacheTicket _ownerTicket;
  final AuthOperationScope _sessionTicket;
}

/// Bounded, process-local proof. Old disk/legacy caches never create entries.
class VerifiedEmptyTeamChats {
  VerifiedEmptyTeamChats({this.maxEntries = 64});
  static final instance = VerifiedEmptyTeamChats();
  final int maxEntries;
  final _entries = LinkedHashMap<_Key, _Entry>();

  EmptyTeamChatAttempt? begin(AuthSessionScope scope, TeamCacheOwner owner) {
    if (!owner.belongsTo(scope)) return null;
    final ticket = owner.capture();
    final session = scope.capture();
    if (ticket == null ||
        session == null ||
        session.userId != owner.userId ||
        maxEntries <= 0) return null;
    final key = (scope, scope.generation, owner.userId, owner.teamId);
    final previous = _entries.remove(key);
    final token = Object();
    _entries[key] = _Entry(token, previous?.ticket, previous?.chatId);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return EmptyTeamChatAttempt._(key, token, owner, ticket, session);
  }

  bool isCurrent(EmptyTeamChatAttempt attempt) =>
      identical(_entries[attempt._key]?.token, attempt._token) &&
      attempt._owner.isCurrent(attempt._ownerTicket) &&
      attempt._key.$1.isCurrent(attempt._sessionTicket);

  void confirm(EmptyTeamChatAttempt attempt, String chatId) {
    if (chatId.isEmpty || !isCurrent(attempt)) return;
    _entries[attempt._key] =
        _Entry(attempt._token, attempt._sessionTicket, chatId);
  }

  String? lookup(AuthSessionScope scope, TeamCacheOwner owner) {
    if (!owner.belongsTo(scope) || owner.capture() == null) return null;
    final key = (scope, scope.generation, owner.userId, owner.teamId);
    final entry = _entries[key];
    if (entry?.ticket == null || !scope.isCurrent(entry!.ticket!)) return null;
    return entry.chatId;
  }

  void invalidate(AuthSessionScope scope, TeamCacheOwner owner) {
    if (!owner.belongsTo(scope) || owner.capture() == null) return;
    _entries.remove((scope, scope.generation, owner.userId, owner.teamId));
  }

  void clear() => _entries.clear();
}

/// Requires one exact team-main mapping and a successful raw empty page.
Future<void> verifyEmptyTeamChat({
  required VerifiedEmptyTeamChats registry,
  required AuthSessionScope scope,
  required TeamCacheOwner owner,
  required Future<Object?> Function() fetchMapping,
  required Future<Object?> Function(String chatId) fetchPage,
  required bool Function() isOpenAndEmpty,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final attempt = registry.begin(scope, owner);
  if (attempt == null) return;
  bool current() => isOpenAndEmpty() && registry.isCurrent(attempt);
  try {
    if (!current()) return;
    final raw = await fetchMapping().timeout(timeout);
    if (!current()) return;
    if (raw is! List || raw.length != 1 || raw.single is! Map) {
      registry.invalidate(scope, owner);
      return;
    }
    final row = raw.single as Map;
    final id = row['id'];
    if (id is! String ||
        id.trim().isEmpty ||
        row['team_id'] != owner.teamId ||
        row['type'] != 'team_main') {
      registry.invalidate(scope, owner);
      return;
    }
    final page = await fetchPage(id).timeout(timeout);
    if (!current()) return;
    if (page is List && page.isEmpty) {
      registry.confirm(attempt, id);
    } else if (page is List && page.isNotEmpty) {
      registry.invalidate(scope, owner);
    }
  } catch (error) {
    if (current() &&
        error is PostgrestException &&
        const {'42501', 'PGRST301', 'PGRST302', 'PT401', 'PT403'}
            .contains(error.code)) {
      registry.invalidate(scope, owner);
    }
    // An error, malformed response or timeout is never evidence of emptiness.
  }
}
