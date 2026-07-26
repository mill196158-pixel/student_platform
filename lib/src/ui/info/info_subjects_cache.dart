import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class InfoSubjectVoteUpdate {
  final String subjectOfferingId;
  final double? effectiveDifficulty;

  const InfoSubjectVoteUpdate({
    required this.subjectOfferingId,
    required this.effectiveDifficulty,
  });
}

/// Coordinates Info-tab subjects cache invalidation across entry points
/// (subject screen vote, schedule → subject info, etc.).
class InfoSubjectsCache {
  InfoSubjectsCache._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void Function()? _clearMemory;
  static InfoSubjectVoteUpdate? _pendingVote;

  /// Called by [InfoScreen] so RAM cache can be cleared without import cycles.
  static void attachMemoryClear(void Function() clear) {
    _clearMemory = clear;
  }

  static void detachMemoryClear(void Function() clear) {
    if (identical(_clearMemory, clear)) {
      _clearMemory = null;
    }
  }

  static String prefsKey(String userId) => 'info_subjects_cache_v3_$userId';

  /// Stages an optimistic difficulty update applied by Info before refetch.
  static void stageVoteUpdate(InfoSubjectVoteUpdate update) {
    _pendingVote = update;
  }

  static InfoSubjectVoteUpdate? takePendingVote() {
    final value = _pendingVote;
    _pendingVote = null;
    return value;
  }

  /// Drops RAM + SharedPreferences cache and notifies listeners to refetch.
  static Future<void> invalidate({String? userId}) async {
    _clearMemory?.call();
    try {
      final id = (userId ?? Supabase.instance.client.auth.currentUser?.id ?? '')
          .trim();
      if (id.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(prefsKey(id));
      }
    } catch (_) {}
    revision.value++;
  }
}
