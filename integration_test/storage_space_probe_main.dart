import 'dart:io';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:student_platform/src/core/support_storage_space.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName != 'com.example.offline_grant_qa') {
    throw StateError('Probe requires isolated package');
  }
  final bytes = await SupportStorageSpace.availableBytes(Directory.systemTemp);
  debugPrint(bytes != null && bytes > 0 ? 'CODEX_SPACE_PROBE_PASS' : 'CODEX_SPACE_PROBE_FAIL');
  runApp(const MaterialApp(home: Scaffold(body: Text('Isolated storage probe'))));
}
