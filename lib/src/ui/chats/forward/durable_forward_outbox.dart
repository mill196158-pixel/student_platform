import 'dart:convert';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import '../../../core/auth_session_scope.dart';
import '../core/forward_payload.dart';
import 'forward_send_gate.dart';

const _createForwardItem = 'CREATE TABLE forward_item ('
    'backend TEXT NOT NULL, uid TEXT NOT NULL, chat TEXT NOT NULL, '
    'op TEXT NOT NULL, version INTEGER NOT NULL CHECK(version>=0), '
    'state TEXT NOT NULL CHECK(state IN (\'reserved_unverified\',\'queued\',\'preparing_unknown\',\'ready\',\'sending_unknown\',\'sent\')), '
    'source TEXT NOT NULL, source_urls TEXT NOT NULL, source_ids TEXT NOT NULL, '
    'prepared TEXT, prepared_ids TEXT, sent_text TEXT, reply_id TEXT, sent_ids TEXT, message_id TEXT, '
    'PRIMARY KEY (backend,uid,chat))';
const _createSentTombstones = 'CREATE TABLE IF NOT EXISTS forward_sent ('
    'backend TEXT NOT NULL, uid TEXT NOT NULL, chat TEXT NOT NULL, '
    'operation TEXT NOT NULL, PRIMARY KEY (backend,uid,chat,operation))';
const _createTerminalTombstones =
    'CREATE TABLE IF NOT EXISTS forward_terminal ('
    'backend TEXT NOT NULL, uid TEXT NOT NULL, chat TEXT NOT NULL, '
    'operation TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN (\'sent\',\'canceled\')), '
    'PRIMARY KEY (backend,uid,chat,operation))';

/// A separate database: no network or user-facing auto-send happens here.
/// The caller must locate this in private app storage and guard account access.
Future<Database> openDurableForwardDatabase(String path,
    {DatabaseFactory? factory}) async {
  return (factory ?? databaseFactory).openDatabase(path,
      options: OpenDatabaseOptions(
          version: 5,
          singleInstance: false,
          onConfigure: (db) async {
            final mode = await db.rawQuery('PRAGMA journal_mode=WAL');
            if (mode.length != 1 ||
                mode.single.values.single.toString().toLowerCase() != 'wal') {
              throw StateError('Forward outbox durability unavailable');
            }
            await db.execute('PRAGMA synchronous=FULL');
          },
          onCreate: (db, _) async {
            await db.execute(_createForwardItem);
            await db.execute(_createSentTombstones);
            await db.execute(_createTerminalTombstones);
            await db.execute(
                'CREATE TABLE IF NOT EXISTS forward_legacy_import ('
                'backend TEXT NOT NULL, uid TEXT NOT NULL, chat TEXT NOT NULL, '
                'fingerprint TEXT NOT NULL, operation TEXT NOT NULL, '
                'PRIMARY KEY (backend,uid,chat,fingerprint))');
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if ((oldVersion < 1 || oldVersion > 4) || newVersion != 5) {
              throw StateError('Unknown forward database migration');
            }
            await db.execute(
                'CREATE TABLE IF NOT EXISTS forward_legacy_import ('
                'backend TEXT NOT NULL, uid TEXT NOT NULL, chat TEXT NOT NULL, '
                'fingerprint TEXT NOT NULL, operation TEXT NOT NULL, '
                'PRIMARY KEY (backend,uid,chat,fingerprint))');
            if (oldVersion < 3) {
              await db.execute(
                  'ALTER TABLE forward_item RENAME TO forward_item_v2');
              await db.execute(_createForwardItem);
              await db.execute('INSERT INTO forward_item '
                  '(backend,uid,chat,op,version,state,source,source_urls,source_ids,prepared,prepared_ids,sent_text,reply_id,sent_ids,message_id) '
                  'SELECT backend,uid,chat,op,version,CASE WHEN state=\'queued\' THEN \'reserved_unverified\' ELSE state END,source,source_urls,source_ids,prepared,prepared_ids,sent_text,reply_id,sent_ids,message_id FROM forward_item_v2');
              await db.execute('DROP TABLE forward_item_v2');
            }
            await db.execute(_createSentTombstones);
            await db.execute(_createTerminalTombstones);
            await db.execute('INSERT OR IGNORE INTO forward_terminal '
                '(backend,uid,chat,operation,kind) SELECT backend,uid,chat,operation,\'sent\' FROM forward_sent');
          },
          onDowngrade: (_, __, ___) =>
              throw StateError('Unknown forward database version'),
          onOpen: (db) async {
            Future<void> verify(
                String table, Map<String, int> requiredColumns) async {
              final rows = await db.rawQuery('PRAGMA table_info($table)');
              final actual = <String, int>{
                for (final row in rows) row['name'] as String: row['pk'] as int
              };
              if (requiredColumns.entries
                  .any((e) => actual[e.key] != e.value)) {
                throw StateError('Invalid forward database schema');
              }
            }

            await verify('forward_item', {
              'backend': 1,
              'uid': 2,
              'chat': 3,
              'op': 0,
              'version': 0,
              'state': 0,
              'source': 0,
              'source_urls': 0,
              'source_ids': 0,
              'prepared': 0,
              'prepared_ids': 0,
              'sent_text': 0,
              'reply_id': 0,
              'sent_ids': 0,
              'message_id': 0,
            });
            await verify('forward_legacy_import', {
              'backend': 1,
              'uid': 2,
              'chat': 3,
              'fingerprint': 4,
              'operation': 0,
            });
            await verify('forward_sent', {
              'backend': 1,
              'uid': 2,
              'chat': 3,
              'operation': 4,
            });
            await verify('forward_terminal', {
              'backend': 1,
              'uid': 2,
              'chat': 3,
              'operation': 4,
              'kind': 0,
            });
          }));
}

enum DurableForwardState {
  reservedUnverified,
  queued,
  preparingUnknown,
  ready,
  sendingUnknown,
  sent
}

String _stateText(DurableForwardState value) => switch (value) {
      DurableForwardState.reservedUnverified => 'reserved_unverified',
      DurableForwardState.queued => 'queued',
      DurableForwardState.preparingUnknown => 'preparing_unknown',
      DurableForwardState.ready => 'ready',
      DurableForwardState.sendingUnknown => 'sending_unknown',
      DurableForwardState.sent => 'sent',
    };
DurableForwardState _stateValue(String value) => switch (value) {
      'reserved_unverified' => DurableForwardState.reservedUnverified,
      'queued' => DurableForwardState.queued,
      'preparing_unknown' => DurableForwardState.preparingUnknown,
      'ready' => DurableForwardState.ready,
      'sending_unknown' => DurableForwardState.sendingUnknown,
      'sent' => DurableForwardState.sent,
      _ => throw const FormatException('Unknown forward state'),
    };

class DurableForwardOccupied implements Exception {
  const DurableForwardOccupied();
}

class DurableForwardChanged implements Exception {
  const DurableForwardChanged();
}

enum LegacyForwardImport { imported, alreadyImported }

class DurableForwardSendSnapshot {
  DurableForwardSendSnapshot(
      this.chat, this.text, this.replyId, List<String> ids)
      : fileIds = List.unmodifiable(ids);
  final String chat, text;
  final String? replyId;
  final List<String> fileIds;
}

/// Immutable, session-bound optimistic-concurrency token. A fresh token is
/// obtained through peek after restart and a new authenticated session.
class DurableForwardReceipt {
  const DurableForwardReceipt._(
      this._store,
      this._owner,
      this.backend,
      this.chat,
      this.operation,
      this.version,
      this.state,
      this.source,
      this.sourceUrls,
      this.sourceIds,
      this.prepared,
      this.preparedIds,
      this.messageId,
      this.sentText,
      this.replyId,
      this.sentIds);
  final Object _store;
  final AuthOperationScope _owner;
  final String backend, chat, operation, source;
  final int version;
  final DurableForwardState state;
  final List<String> sourceUrls, sourceIds;
  final String? prepared, messageId;
  final List<String>? preparedIds;
  final String? sentText, replyId;
  final List<String>? sentIds;
}

class DurableForwardOutbox {
  DurableForwardOutbox(this.db, this.scope, this.backend) {
    if (backend.trim().isEmpty) throw ArgumentError('Missing backend identity');
  }
  final Database db;
  final AuthSessionScope scope;
  final String backend;
  final _issuer = Object();
  final _random = Random.secure();
  void _check(AuthOperationScope owner) {
    if (!scope.isCurrent(owner)) throw StateError('Session changed');
  }

  void _checkReceipt(DurableForwardReceipt receipt) {
    if (!identical(receipt._store, _issuer) || receipt.backend != backend) {
      throw const DurableForwardChanged();
    }
    _check(receipt._owner);
  }

  String _newOperation() => List.generate(24, (_) => _random.nextInt(256))
      .map((n) => n.toRadixString(16).padLeft(2, '0'))
      .join();
  static List<String> _parseList(Object? value) {
    final decoded = jsonDecode(value as String);
    if (decoded is! List || decoded.any((e) => e is! String))
      throw const FormatException();
    return List.unmodifiable(decoded.cast<String>());
  }

  DurableForwardReceipt _receipt(
      AuthOperationScope owner, String chat, Map<String, Object?> row) {
    final state = _stateValue(row['state'] as String);
    return DurableForwardReceipt._(
        _issuer,
        owner,
        backend,
        chat,
        row['op'] as String,
        row['version'] as int,
        state,
        row['source'] as String,
        _parseList(row['source_urls']),
        _parseList(row['source_ids']),
        row['prepared'] as String?,
        row['prepared_ids'] == null ? null : _parseList(row['prepared_ids']),
        row['message_id'] as String?,
        row['sent_text'] as String?,
        row['reply_id'] as String?,
        row['sent_ids'] == null ? null : _parseList(row['sent_ids']));
  }

  List<Object?> _key(AuthOperationScope owner, String chat) =>
      [backend, owner.userId, chat];
  Future<List<Map<String, Object?>>> _select(
          DatabaseExecutor tx, AuthOperationScope owner, String chat) =>
      tx.rawQuery(
          'SELECT op,version,state,source,source_urls,source_ids,prepared,prepared_ids,message_id,sent_text,reply_id,sent_ids '
          'FROM forward_item WHERE backend=? AND uid=? AND chat=?',
          _key(owner, chat));

  Future<DurableForwardReceipt?> peek(
      AuthOperationScope owner, String chat) async {
    _check(owner);
    if (chat.trim().isEmpty) throw const FormatException('Missing chat');
    final result = await db.transaction((tx) async {
      _check(owner);
      final rows = await _select(tx, owner, chat);
      _check(owner);
      if (rows.length > 1) throw StateError('Duplicate forward slot');
      return rows.isEmpty ? null : _receipt(owner, chat, rows.single);
    });
    _check(owner);
    return result;
  }

  /// Permanent evidence lets a stale draft sentinel be safely removed even
  /// if the process died after the queue row was acknowledged.
  Future<Set<String>> terminalOperations(
      AuthOperationScope owner, String chat) async {
    _check(owner);
    if (chat.trim().isEmpty || chat != chat.trim())
      throw const FormatException();
    final rows = await db.rawQuery(
        'SELECT operation FROM forward_terminal WHERE backend=? AND uid=? AND chat=?',
        _key(owner, chat));
    _check(owner);
    return Set.unmodifiable(rows.map((row) => row['operation'] as String));
  }

  /// Atomically persists both the queued payload and a permanent import marker.
  /// The caller must CAS-ack the exact legacy receipt only after this returns.
  /// A marker survives queue acknowledgement to prevent stale resurrection.
  Future<LegacyForwardImport> importLegacy(
      AuthOperationScope owner, String chat,
      {required String fingerprint,
      required String source,
      required List<String> sourceUrls,
      required List<String> sourceIds}) async {
    _check(owner);
    if (chat.trim().isEmpty ||
        chat != chat.trim() ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('Invalid legacy identity');
    }
    final parsed = ForwardPayload.tryParse(source);
    final urls = List<String>.of(sourceUrls), ids = List<String>.of(sourceIds);
    if (parsed == null ||
        !forwardSourceReferencesComplete(parsed, ids) ||
        urls.any((s) => s.trim().isEmpty) ||
        ids.any((s) => s.trim().isEmpty)) {
      throw const FormatException('Invalid legacy forward');
    }
    final result = await db.transaction((tx) async {
      _check(owner);
      final marker = await tx.rawQuery(
          'SELECT operation FROM forward_legacy_import WHERE backend=? AND uid=? AND chat=? AND fingerprint=?',
          [..._key(owner, chat), fingerprint]);
      _check(owner);
      if (marker.length > 1) throw StateError('Duplicate legacy import marker');
      if (marker.isNotEmpty) return LegacyForwardImport.alreadyImported;
      if ((await _select(tx, owner, chat)).isNotEmpty) {
        throw const DurableForwardOccupied();
      }
      _check(owner);
      final op = _newOperation();
      final inserted = await tx.rawInsert(
          'INSERT INTO forward_item (backend,uid,chat,op,version,state,source,source_urls,source_ids) VALUES (?,?,?,?,0,?,?,?,?)',
          [
            backend,
            owner.userId,
            chat,
            op,
            'reserved_unverified',
            source,
            jsonEncode(urls),
            jsonEncode(ids)
          ]);
      if (inserted <= 0) throw StateError('Legacy reserve failed');
      _check(owner);
      final marked = await tx.rawInsert(
          'INSERT INTO forward_legacy_import (backend,uid,chat,fingerprint,operation) VALUES (?,?,?,?,?)',
          [backend, owner.userId, chat, fingerprint, op]);
      if (marked <= 0) throw StateError('Legacy marker failed');
      _check(owner);
      return LegacyForwardImport.imported;
    });
    _check(owner);
    return result;
  }

  /// Never overwrites even corrupt or unknown records in this chat slot.
  Future<DurableForwardReceipt> reserve(AuthOperationScope owner, String chat,
      {required String source,
      required List<String> sourceUrls,
      required List<String> sourceIds,
      bool Function()? isSourceCurrent}) async {
    void check() {
      _check(owner);
      if (!(isSourceCurrent?.call() ?? true))
        throw const DurableForwardChanged();
    }

    check();
    if (chat.trim().isEmpty || chat != chat.trim())
      throw const FormatException('Missing chat');
    final parsed = ForwardPayload.tryParse(source);
    if (parsed == null || !forwardSourceReferencesComplete(parsed, sourceIds))
      throw const FormatException('Invalid forward');
    final urls = List<String>.of(sourceUrls), ids = List<String>.of(sourceIds);
    if (urls.any((s) => s.trim().isEmpty) || ids.any((s) => s.trim().isEmpty))
      throw const FormatException('Invalid file');
    final op = _newOperation();
    final result = await db.transaction((tx) async {
      check();
      if ((await _select(tx, owner, chat)).isNotEmpty)
        throw const DurableForwardOccupied();
      check();
      final count = await tx.rawInsert(
          'INSERT INTO forward_item '
          '(backend,uid,chat,op,version,state,source,source_urls,source_ids) VALUES (?,?,?,?,0,?,?,?,?)',
          [
            backend,
            owner.userId,
            chat,
            op,
            'reserved_unverified',
            source,
            jsonEncode(urls),
            jsonEncode(ids)
          ]);
      if (count <= 0) throw StateError('Forward reserve failed');
      check();
      final rows = await _select(tx, owner, chat);
      check();
      if (rows.length != 1) throw StateError('Forward reserve failed');
      return _receipt(owner, chat, rows.single);
    });
    check();
    return result;
  }

  Future<DurableForwardReceipt> _transition(
      DurableForwardReceipt r, DurableForwardState from, DurableForwardState to,
      {String? prepared,
      List<String>? preparedIds,
      String? messageId,
      String? sentText,
      String? replyId,
      List<String>? sentIds}) async {
    _checkReceipt(r);
    if (r.state != from) throw const DurableForwardChanged();
    final result = await db.transaction((tx) async {
      _checkReceipt(r);
      final changed = await tx.rawUpdate(
          'UPDATE forward_item SET version=version+1,state=?, '
          'prepared=COALESCE(?,prepared), prepared_ids=COALESCE(?,prepared_ids), message_id=COALESCE(?,message_id), '
          'sent_text=COALESCE(?,sent_text), reply_id=COALESCE(?,reply_id), sent_ids=COALESCE(?,sent_ids) '
          'WHERE backend=? AND uid=? AND chat=? AND op=? AND version=? AND state=?',
          [
            _stateText(to),
            prepared,
            preparedIds == null ? null : jsonEncode(preparedIds),
            messageId,
            sentText,
            replyId,
            sentIds == null ? null : jsonEncode(sentIds),
            backend,
            r._owner.userId,
            r.chat,
            r.operation,
            r.version,
            _stateText(from)
          ]);
      _checkReceipt(r);
      if (changed != 1) throw const DurableForwardChanged();
      final rows = await _select(tx, r._owner, r.chat);
      _checkReceipt(r);
      if (rows.length != 1) throw const DurableForwardChanged();
      return _receipt(r._owner, r.chat, rows.single);
    });
    _checkReceipt(r);
    return result;
  }

  /// Called after source validation, or after explicit user confirmation.
  Future<DurableForwardReceipt> confirmReservation(DurableForwardReceipt r) =>
      _transition(r, DurableForwardState.reservedUnverified,
          DurableForwardState.queued);

  /// Call immediately before any upload. After crash this state is ambiguous.
  Future<DurableForwardReceipt> markPreparing(DurableForwardReceipt r) =>
      _transition(
          r, DurableForwardState.queued, DurableForwardState.preparingUnknown);

  /// Explicit action only: previous uploads may remain on the server.
  Future<DurableForwardReceipt> retryPreparationByUser(
          DurableForwardReceipt r) =>
      _transition(
          r, DurableForwardState.preparingUnknown, DurableForwardState.queued);

  /// A complete prepared snapshot must be durably saved before it can be sent.
  Future<DurableForwardReceipt> markReady(DurableForwardReceipt r,
      {required String prepared,
      required List<String> preparedIds,
      required Map<String, String> uploadedIdsBySource}) {
    final frozen = List<String>.of(preparedIds);
    final uploaded = Map<String, String>.of(uploadedIdsBySource);
    final parsed = ForwardPayload.tryParse(prepared);
    final original = ForwardPayload.tryParse(r.source);
    if (parsed == null ||
        original == null ||
        frozen.any((id) => id.trim().isEmpty) ||
        frozen.toSet().length != frozen.length ||
        !forwardSourceReferencesComplete(parsed, frozen)) {
      throw const FormatException('Invalid prepared forward');
    }
    final originals = original.allFiles();
    final replacements = parsed.allFiles();
    final sourceUrls = {...r.sourceUrls, ...originals.map((item) => item.url)};
    if (sourceUrls.any((url) => url.trim().isEmpty) ||
        frozen.length != sourceUrls.length ||
        uploaded.length != sourceUrls.length ||
        !uploaded.keys.toSet().containsAll(sourceUrls) ||
        uploaded.values.toSet().length != frozen.length ||
        !uploaded.values.toSet().containsAll(frozen) ||
        originals.length != replacements.length) {
      throw const FormatException('Incomplete prepared forward');
    }
    final copied = <String, ForwardFileRef>{};
    for (var i = 0; i < originals.length; i++) {
      final before = originals[i], after = replacements[i];
      final id = after.id;
      if (id == null || id.trim().isEmpty || uploaded[before.url] != id) {
        throw const FormatException('Incomplete prepared forward');
      }
      final previous = copied[before.url];
      if (previous != null &&
          (previous.id != after.id || previous.url != after.url)) {
        throw const FormatException('Inconsistent prepared forward');
      }
      copied[before.url] = after;
    }
    if (jsonEncode(original.withCopiedFiles(copied).toJson()) !=
        jsonEncode(parsed.toJson())) {
      throw const FormatException('Changed prepared forward');
    }
    return _transition(
        r, DurableForwardState.preparingUnknown, DurableForwardState.ready,
        prepared: prepared, preparedIds: frozen);
  }

  /// Commit this before send. Reopening in sendingUnknown never sends again.
  Future<DurableForwardReceipt> markSending(DurableForwardReceipt r,
      {required String text,
      required String? replyId,
      required List<String> fileIds}) {
    final ids = List<String>.of(fileIds);
    final prepared =
        r.prepared == null ? null : ForwardPayload.tryParse(r.prepared!);
    final sending = ForwardPayload.tryParse(text);
    // The caption may be edited, but a different body cannot acknowledge
    // and remove the prepared forward.
    String body(ForwardPayload payload) => jsonEncode(ForwardPayload(
          fromChatId: payload.fromChatId,
          items: payload.items,
        ).toJson());
    if (ids.any((id) => id.trim().isEmpty) ||
        ids.toSet().length != ids.length ||
        r.preparedIds == null ||
        prepared == null ||
        sending == null ||
        body(prepared) != body(sending) ||
        !ids.toSet().containsAll(r.preparedIds!) ||
        (r.sentText != null &&
            (r.sentText != text ||
                r.replyId != replyId ||
                jsonEncode(r.sentIds) != jsonEncode(ids)))) {
      throw const FormatException('Incomplete send snapshot');
    }
    return _transition(
        r, DurableForwardState.ready, DurableForwardState.sendingUnknown,
        sentText: text, replyId: replyId, sentIds: ids);
  }

  Future<DurableForwardReceipt> _markSent(
      DurableForwardReceipt r, String messageId) {
    if (!RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        .hasMatch(messageId)) {
      throw const FormatException('Unconfirmed send');
    }
    return _transition(
        r, DurableForwardState.sendingUnknown, DurableForwardState.sent,
        messageId: messageId);
  }

  /// Commit unknown before invoking exactly one callback. On any failure or
  /// session change the row remains unknown; only an explicit user action may
  /// later retry. The callback must send the provided immutable snapshot.
  Future<DurableForwardReceipt> sendOnce(DurableForwardReceipt ready,
      {required String text,
      required String? replyId,
      required List<String> fileIds,
      required Future<String> Function(DurableForwardSendSnapshot)
          send}) async {
    final snapshot =
        DurableForwardSendSnapshot(ready.chat, text, replyId, fileIds);
    final sending = await markSending(ready,
        text: snapshot.text,
        replyId: snapshot.replyId,
        fileIds: snapshot.fileIds);
    _checkReceipt(sending);
    final id = await send(snapshot);
    _checkReceipt(sending);
    return _markSent(sending, id);
  }

  /// Only after an explicit warning and user action. Never transitions back
  /// to ready: a crash at any point must still reopen as unknown.
  Future<DurableForwardReceipt> retryUnknownByUser(DurableForwardReceipt r,
      {required Future<String> Function(DurableForwardSendSnapshot)
          send}) async {
    if (r.sentText == null || r.sentIds == null) {
      throw const FormatException('Missing original send snapshot');
    }
    final snapshot =
        DurableForwardSendSnapshot(r.chat, r.sentText!, r.replyId, r.sentIds!);
    final retry = await _transition(r, DurableForwardState.sendingUnknown,
        DurableForwardState.sendingUnknown);
    _checkReceipt(retry);
    final id = await send(snapshot);
    _checkReceipt(retry);
    return _markSent(retry, id);
  }

  /// Only a confirmed sent record may be acknowledged without user action.
  Future<bool> acknowledgeSent(DurableForwardReceipt r) =>
      _remove(r, onlySent: true);

  /// Call only in direct response to an explicit user cancellation.
  Future<bool> cancelByUser(DurableForwardReceipt r) =>
      _remove(r, onlySent: false);
  Future<bool> _remove(DurableForwardReceipt r,
      {required bool onlySent}) async {
    _checkReceipt(r);
    if (onlySent && r.state != DurableForwardState.sent)
      throw const DurableForwardChanged();
    final removed = await db.transaction((tx) async {
      _checkReceipt(r);
      final kind = r.state == DurableForwardState.sent ? 'sent' : 'canceled';
      await tx.rawInsert(
          'INSERT OR IGNORE INTO forward_terminal (backend,uid,chat,operation,kind) VALUES (?,?,?,?,?)',
          [backend, r._owner.userId, r.chat, r.operation, kind]);
      _checkReceipt(r);
      final marker = await tx.rawQuery(
          'SELECT kind FROM forward_terminal WHERE backend=? AND uid=? AND chat=? AND operation=?',
          [backend, r._owner.userId, r.chat, r.operation]);
      _checkReceipt(r);
      if (marker.length != 1 || marker.single['kind'] != kind) {
        throw StateError('Forward terminal marker conflict');
      }
      final count = await tx.rawDelete(
          'DELETE FROM forward_item WHERE backend=? AND uid=? AND chat=? '
          'AND op=? AND version=? AND state=?',
          [
            backend,
            r._owner.userId,
            r.chat,
            r.operation,
            r.version,
            _stateText(r.state)
          ]);
      _checkReceipt(r);
      if (count != 1) throw const DurableForwardChanged();
      return true;
    });
    _checkReceipt(r);
    return removed;
  }
}
