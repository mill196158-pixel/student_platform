import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// Attach the already-open, guarded chat database to the guarded media
/// connection. A conflicting alias is never detached or replaced here.
Future<String?> attachSourceSnapshot(Database media, Database chat) async {
  try {
    if (!media.isOpen || !chat.isOpen || identical(media, chat)) return null;
    if (await FileSystemEntity.type(chat.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await FileSystemEntity.type(media.path, followLinks: false) !=
            FileSystemEntityType.file) return null;
    final expected = await File(chat.path).resolveSymbolicLinks();
    final main = await File(media.path).resolveSymbolicLinks();
    bool same(String a, String b) =>
        Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
    if (same(expected, main)) return null;
    Future<bool> isAttached() async {
      final rows = await media.rawQuery('PRAGMA database_list');
      final matches =
          rows.where((row) => row['name'] == 'source_snapshot').toList();
      if (matches.length != 1 || matches.single['file'] is! String)
        return false;
      final actual =
          await File(matches.single['file'] as String).resolveSymbolicLinks();
      return same(actual, expected);
    }

    final rows = await media.rawQuery('PRAGMA database_list');
    if (rows.any((row) => row['name'] == 'source_snapshot'))
      return await isAttached() ? expected : null;
    try {
      await media.execute('ATTACH DATABASE ? AS source_snapshot', [expected]);
    } catch (_) {
      /* An earlier concurrent attach is accepted only if identical. */
    }
    return await isAttached() && media.isOpen && chat.isOpen ? expected : null;
  } catch (_) {
    return null;
  }
}
