import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileRepository {
  final _sb = Supabase.instance.client;

  Future<Map<String, dynamic>?> fetchMyProfile() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return null;
    return await _sb
        .from('users')
        .select<Map<String, dynamic>>()
        .eq('id', uid)
        .maybeSingle();
  }

  Future<void> updateProfile({
    required String name,
    required String surname,
    required String university,
    required String groupName,
    String? status,
  }) async {
    final uid = _sb.auth.currentUser!.id;
    await _sb.from('users').update({
      'name': name,
      'surname': surname,
      'university': university,
      'group_name': groupName,
      if (status != null) 'status': status,
    }).eq('id', uid);
  }

  /// Кладём в `<uid>/<filename>.jpg`
  Future<String?> uploadAvatar(File file) async {
    final uid = _sb.auth.currentUser!.id;
    final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final path = '$uid/$fileName';

    await _sb.storage.from('avatars').upload(
      path,
      file,
      fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'),
    );

    final publicUrl = _sb.storage.from('avatars').getPublicUrl(path);
    await _sb.from('users').update({'avatar_url': publicUrl}).eq('id', uid);
    return publicUrl;
  }
}
