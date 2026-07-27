import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/file_service.dart';
import '../models/group_space.dart';

/// Cache-first access to the permanent academic group space.
class GroupSpaceRepository {
  GroupSpaceRepository({
    SupabaseClient? client,
    FileService? fileService,
  })  : _client = client ?? Supabase.instance.client,
        _fileService = fileService ?? FileService();

  final SupabaseClient _client;
  final FileService _fileService;

  static const _cachePrefix = 'group_space_v1_';

  String? get _userId => _client.auth.currentUser?.id;

  String _cacheKey(String suffix) {
    final uid = _userId ?? 'anon';
    return '$_cachePrefix${uid}_$suffix';
  }

  Future<GroupSpaceSnapshot?> peekCachedSpace() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey('space'));
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) {
        return GroupSpaceSnapshot.fromJson(map);
      }
      if (map is Map) {
        return GroupSpaceSnapshot.fromJson(Map<String, dynamic>.from(map));
      }
    } catch (_) {}
    return null;
  }

  Future<void> _storeCachedSpace(GroupSpaceSnapshot space) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cacheKey('space'),
      jsonEncode({
        'group_id': space.groupId,
        'team_id': space.teamId,
        'chat_id': space.chatId,
        'title': space.title,
        'is_organizer': space.isOrganizer,
      }),
    );
  }

  Future<GroupSpaceSnapshot> ensureSpace() async {
    final res = await _client.rpc('ensure_group_space');
    final space = GroupSpaceSnapshot.fromJson(_asMap(res));
    await _storeCachedSpace(space);
    return space;
  }

  Future<GroupSpaceSnapshot> getMySpace({bool createIfMissing = false}) async {
    if (createIfMissing) return ensureSpace();
    final res = await _client.rpc('get_my_group_space');
    final space = GroupSpaceSnapshot.fromJson(_asMap(res));
    if (space.exists) await _storeCachedSpace(space);
    return space;
  }

  Future<List<GroupCollection>> listCollections() async {
    final res = await _client.rpc('list_group_collections');
    final rows = _asList(res);
    return rows.map(GroupCollection.fromJson).toList();
  }

  Future<String> createCollection({
    required String title,
    String description = '',
    String purpose = '',
    DateTime? deadlineAt,
    double? amountOptional,
  }) async {
    final id = await _client.rpc(
      'create_group_collection',
      params: {
        'p_title': title,
        'p_description': description,
        'p_purpose': purpose,
        'p_deadline_at': deadlineAt?.toIso8601String(),
        'p_amount_optional': amountOptional,
      },
    );
    return id.toString();
  }

  Future<void> updateCollectionStatus({
    required String collectionId,
    required String status,
  }) {
    return _client.rpc(
      'update_group_collection_status',
      params: {
        'p_collection_id': collectionId,
        'p_status': status,
      },
    );
  }

  Future<void> upsertMyContribution({
    required String collectionId,
    String participationStatus = 'unmarked',
    String paymentStatus = 'unmarked',
    double? amount,
    String comment = '',
    String? proofFileId,
  }) {
    return _client.rpc(
      'upsert_my_collection_contribution',
      params: {
        'p_collection_id': collectionId,
        'p_participation_status': participationStatus,
        'p_payment_status': paymentStatus,
        'p_amount': amount,
        'p_comment': comment,
        'p_proof_file_id': proofFileId,
      },
    );
  }

  Future<void> confirmContribution({
    required String collectionId,
    required String userId,
    required String paymentStatus,
  }) {
    return _client.rpc(
      'confirm_collection_contribution',
      params: {
        'p_collection_id': collectionId,
        'p_user_id': userId,
        'p_payment_status': paymentStatus,
      },
    );
  }

  Future<List<Map<String, dynamic>>> listCollectionContributions(
    String collectionId,
  ) async {
    final res = await _client
        .from('group_collection_contributions')
        .select(
          'id,user_id,participation_status,payment_status,amount,comment,proof_file_id,updated_at',
        )
        .eq('collection_id', collectionId)
        .order('updated_at', ascending: false);
    final rows = _asList(res);
    final proofIds = rows
        .map((e) => e['proof_file_id']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    final proofs = <String, Map<String, dynamic>>{};
    if (proofIds.isNotEmpty) {
      final files = await _client
          .from('chat_files')
          .select('id,file_name,file_url,file_type')
          .inFilter('id', proofIds);
      for (final file in _asList(files)) {
        final id = file['id']?.toString() ?? '';
        if (id.isNotEmpty) proofs[id] = file;
      }
    }
    return rows.map((row) {
      final proofId = row['proof_file_id']?.toString() ?? '';
      final proof = proofs[proofId];
      return {
        ...row,
        'proof_file_name': proof?['file_name'],
        'proof_file_url': proof?['file_url'],
        'proof_file_type': proof?['file_type'],
      };
    }).toList();
  }

  /// Uploads a proof screenshot via the existing chat file pipeline.
  Future<String> uploadProofFile({
    required String chatId,
    required String localPath,
  }) async {
    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      throw StateError('not_authenticated');
    }
    final upload = await _fileService.uploadFile(
      file: File(localPath),
      chatId: chatId,
    );
    if (!upload.success) {
      throw StateError(upload.error ?? 'proof_upload_failed');
    }
    final inserted = await _client
        .from('chat_files')
        .insert({
          'chat_id': chatId,
          'file_name': upload.fileName,
          'file_key': upload.fileKey,
          'file_url': upload.fileUrl,
          'file_type': upload.fileType,
          'file_size': upload.fileSize,
          'uploaded_by': uid,
        })
        .select('id')
        .single();
    final id = inserted['id']?.toString() ?? '';
    if (id.isEmpty) throw StateError('proof_file_missing');
    return id;
  }

  Future<List<GroupTopicSelection>> listTopicSelections() async {
    final res = await _client.rpc('list_topic_selections');
    return _asList(res).map(GroupTopicSelection.fromJson).toList();
  }

  Future<List<GroupTopicOption>> listTopicOptions(String selectionId) async {
    final optionsRes = await _client
        .from('group_topic_options')
        .select('id,selection_id,title,capacity,sort_order')
        .eq('selection_id', selectionId)
        .order('sort_order');
    final picksRes = await _client
        .from('group_topic_picks')
        .select('option_id')
        .eq('selection_id', selectionId);
    final counts = <String, int>{};
    for (final row in _asList(picksRes)) {
      final optionId = row['option_id']?.toString() ?? '';
      if (optionId.isEmpty) continue;
      counts[optionId] = (counts[optionId] ?? 0) + 1;
    }
    return _asList(optionsRes).map((row) {
      final id = row['id'].toString();
      return GroupTopicOption.fromJson({
        ...row,
        'taken': counts[id] ?? 0,
      });
    }).toList();
  }

  Future<String?> myTopicPick(String selectionId) async {
    final uid = _userId;
    if (uid == null) return null;
    final row = await _client
        .from('group_topic_picks')
        .select('option_id')
        .eq('selection_id', selectionId)
        .eq('user_id', uid)
        .maybeSingle();
    return row == null ? null : row['option_id']?.toString();
  }

  Future<String> createTopicSelection({
    required String title,
    String description = '',
    DateTime? deadlineAt,
    bool allowChange = true,
  }) async {
    final id = await _client.rpc(
      'create_topic_selection',
      params: {
        'p_title': title,
        'p_description': description,
        'p_deadline_at': deadlineAt?.toIso8601String(),
        'p_allow_change': allowChange,
      },
    );
    return id.toString();
  }

  Future<String> addTopicOption({
    required String selectionId,
    required String title,
    required int capacity,
    int sortOrder = 0,
  }) async {
    final id = await _client.rpc(
      'add_topic_option',
      params: {
        'p_selection_id': selectionId,
        'p_title': title,
        'p_capacity': capacity,
        'p_sort_order': sortOrder,
      },
    );
    return id.toString();
  }

  Future<void> pickTopic({
    required String selectionId,
    required String optionId,
  }) {
    return _client.rpc(
      'pick_topic',
      params: {
        'p_selection_id': selectionId,
        'p_option_id': optionId,
      },
    );
  }

  Future<void> cancelTopicPick(String selectionId) {
    return _client.rpc(
      'cancel_topic_pick',
      params: {'p_selection_id': selectionId},
    );
  }

  Future<void> closeTopicSelection({
    required String selectionId,
    String status = 'closed',
  }) {
    return _client.rpc(
      'close_topic_selection',
      params: {
        'p_selection_id': selectionId,
        'p_status': status,
      },
    );
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  List<Map<String, dynamic>> _asList(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Object>()
          .map((e) {
            if (e is Map<String, dynamic>) return e;
            if (e is Map) return Map<String, dynamic>.from(e);
            return <String, dynamic>{};
          })
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }
}
