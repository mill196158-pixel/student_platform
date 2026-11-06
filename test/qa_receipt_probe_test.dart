import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/services/qa_receipt_probe.dart';

void main() {
  test('sequential probe denies missing, corrupt, denied and pending receipts', () async {
    final dir = await Directory.systemTemp.createTemp('qa_receipt_probe_');
    final path = '${dir.path}${Platform.pathSeparator}object';
    final file = File(path), grant = File('$path.grant'), pending = File('$path.pending'), denied = File('$path.denied');
    await file.writeAsBytes([1, 2, 3]);
    expect(qaReceiptProbeSync(path, 'sid'), QaReceiptProbeResult.denied);
    await grant.writeAsString('chat-file-grant-v2:sid');
    expect(qaReceiptProbeSync(path, 'sid'), QaReceiptProbeResult.allowed);
    expect(qaReceiptProbeSync(path, 'other'), QaReceiptProbeResult.denied);
    await denied.writeAsString('denied');
    expect(qaReceiptProbeSync(path, 'sid'), QaReceiptProbeResult.denied);
    await denied.delete();
    await grant.rename(pending.path);
    expect(qaReceiptProbeSync(path, 'sid'), QaReceiptProbeResult.pending);
    await pending.rename(grant.path);
    await file.writeAsBytes([]);
    expect(qaReceiptProbeSync(path, 'sid'), QaReceiptProbeResult.denied);
    expect(dir.path.contains('qa_receipt_probe_'), true);
    await dir.delete(recursive: true);
  });

  test('external process moves grant to pending after pending stat', () async {
    final dir = await Directory.systemTemp.createTemp('qa_receipt_probe_external_');
    final path = '${dir.path}${Platform.pathSeparator}object';
    final file = File(path), grant = File('$path.grant'), pending = File('$path.pending');
    await file.writeAsBytes([1]); await grant.writeAsString('chat-file-grant-v2:sid');
    final result = qaReceiptProbeSync(path, 'sid', debugStage: (stage) {
      if (stage != 'pending_checked') return;
      final process = Process.runSync('python', ['-c', 'import os,sys; os.replace(sys.argv[1],sys.argv[2])', grant.path, pending.path]);
      expect(process.exitCode, 0);
    });
    expect(result, QaReceiptProbeResult.denied);
    expect(pending.existsSync(), true);
    expect(dir.path.contains('qa_receipt_probe_external_'), true);
    await dir.delete(recursive: true);
  });
}
