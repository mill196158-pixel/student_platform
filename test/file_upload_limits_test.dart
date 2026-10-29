import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/services/file_service.dart';

void main() {
  test(
      'rejects empty and oversized files before network or reading file contents',
      () async {
    final dir = await Directory.systemTemp.createTemp('upload-limit-');
    final client = SupabaseClient('http://127.0.0.1:1', 'test');
    final service = FileService(supabase: client);
    try {
      final file = File('${dir.path}/sample.bin');
      await file.writeAsBytes([]);
      final empty = await service.uploadFile(file: file, chatId: 'unused');
      expect(empty.success, isFalse);
      expect(empty.error, contains('100 МБ'));
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(FileService.maxUploadBytes + 1);
      await handle.close();
      final large = await service.uploadFile(file: file, chatId: 'unused');
      expect(large.success, isFalse);
      expect(large.error, contains('100 МБ'));
    } finally {
      service.dispose();
      await client.dispose();
      await File('${dir.path}/sample.bin').delete();
      await dir.delete();
    }
  });
}
