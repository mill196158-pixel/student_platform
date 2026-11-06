import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/ui/learning/global_cache.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/attachments/chat_attachments_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _CaptureAdapter implements HttpClientAdapter {
  final bodies = <Uint8List>[];
  final headers = <Map<String, dynamic>>[];
  bool failNext = false;
  Completer<void>? putEntered, putRelease;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    expect(options.uri.host, 'upload.invalid');
    headers.add(Map<String, dynamic>.from(options.headers));
    final data = BytesBuilder(copy: false);
    if (stream != null)
      await for (final chunk in stream) {
        data.add(chunk);
      }
    bodies.add(data.takeBytes());
    final entered = putEntered, release = putRelease;
    if (entered != null && release != null) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      putEntered = null;
      putRelease = null;
    }
    if (failNext) {
      failNext = false;
      return ResponseBody.fromString('synthetic failure', 500);
    }
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _chunk(String type, List<int> payload) {
  final name = ascii.encode(type);
  final size = ByteData(4)..setUint32(0, payload.length);
  final crc = ByteData(4)..setUint32(0, getCrc32([...name, ...payload]));
  return Uint8List.fromList([
    ...size.buffer.asUint8List(),
    ...name,
    ...payload,
    ...crc.buffer.asUint8List()
  ]);
}

Uint8List _png({bool animated = false}) {
  const w = 256, h = 256;
  final header = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      final c = (x ~/ 8 + y ~/ 8).isEven ? 0 : 255;
      raw.add([c, c, c, x < 64 ? 0 : 255]);
    }
  }
  return Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ..._chunk('IHDR', header.buffer.asUint8List()),
    if (animated) ..._chunk('acTL', [0, 0, 0, 1, 0, 0, 0, 0]),
    ..._chunk('IDAT', ZLibEncoder(level: 0).convert(raw.takeBytes())),
    ..._chunk('IEND', [])
  ]);
}

Future<Uint8List> _rgba(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  return data!.buffer.asUint8List();
}

String _session(String uid,
    {String sid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    String refresh = 'test-refresh'}) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return jsonEncode({
    'access_token': '${part({'alg': 'none'})}.${part({
          'sub': uid,
          'session_id': sid,
          'iat': now,
          'exp': now + 3600
        })}.sig',
    'refresh_token': refresh,
    'token_type': 'bearer',
    'expires_at': now + 3600,
    'user': {
      'id': uid,
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-01-01T00:00:00Z'
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'synthetic photo, file and forward traverse actual upload bytes without network',
      () async {
    SharedPreferences.setMockInitialValues({});
    final presigns = <Map<String, dynamic>>[];
    var confirms = 0, saves = 0, totalHttp = 0;
    final savedRows = <Map<String, dynamic>>[];
    Completer<void>? presignEntered, presignRelease;
    final mock = MockClient((request) async {
      totalHttp++;
      final path = request.url.path;
      if (path.endsWith('/generate-upload-url')) {
        presigns
            .add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        final entered = presignEntered, release = presignRelease;
        if (entered != null && release != null) {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          presignEntered = null;
          presignRelease = null;
        }
        return http.Response(
            jsonEncode({
              'uploadUrl': 'https://upload.invalid/object',
              'fileKey': 'chats/test/object',
              'fileUrl': 'https://example.invalid/object',
              'headers': <String, String>{
                'Content-Type': presigns.last['contentType'] as String
              }
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request);
      }
      if (path.endsWith('/chat-file-access')) {
        final body = jsonDecode(request.body) as Map;
        expect(body['action'], 'confirm');
        expect(body['key'], 'chats/test/object');
        expect(body.keys.toSet(), {'action', 'key'});
        confirms++;
        return http.Response('{"confirmed":true}', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      if (path.endsWith('/rpc/save_chat_file')) {
        savedRows
            .add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        saves++;
        return http.Response('"synthetic-file-id"', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      fail('Unexpected HTTP request to ${request.url.path}');
    });
    await Supabase.initialize(
        url: 'https://example.invalid',
        publishableKey: 'test',
        httpClient: mock,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final client = Supabase.instance.client;
    const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await client.auth.setInitialSession(_session(uid));
    final adapter = _CaptureAdapter(), dio = Dio()..httpClientAdapter = adapter;
    final service = FileService(supabase: client, dio: dio);
    final dir = await Directory.systemTemp.createTemp('chat_image_injected_');
    final files = <File>[];
    Future<File> source(String name, Uint8List bytes) async {
      final file = File('${dir.path}/$name');
      files.add(file);
      await file.writeAsBytes(bytes);
      return file;
    }

    Future<void> upload(File file, Uint8List before,
        {required bool preserve}) async {
      final index = adapter.bodies.length;
      final saved = await service.uploadFileToChat(
          file: file,
          chatId: 'chat',
          messageId: '',
          uploadedBy: uid,
          preserveOriginal: preserve);
      final bytes = adapter.bodies[index], request = presigns[index];
      expect(saved.fileSize, bytes.length);
      expect(request['fileSize'], bytes.length);
      expect(request['fileName'], saved.fileName);
      expect(request['contentType'], saved.fileType);
      final contentType = adapter.headers[index].entries
          .singleWhere((e) => e.key.toLowerCase() == 'content-type')
          .value;
      expect(contentType, saved.fileType);
      expect(crypto.sha256.convert(await file.readAsBytes()),
          crypto.sha256.convert(before));
      expect(confirms, index + 1);
    }

    try {
      final photo = image.Image(width: 480, height: 320);
      for (var y = 0; y < photo.height; y++) {
        for (var x = 0; x < photo.width; x++) {
          photo.setPixelRgb(
              x, y, (x ~/ 2) % 256, (y ~/ 2) % 256, ((x + y) ~/ 4) % 256);
        }
      }
      for (var orientation = 1; orientation <= 8; orientation++) {
        photo.exif.imageIfd.orientation = orientation;
        final original = image.encodeJpg(photo, quality: 98);
        final file = await source('photo-$orientation.jpg', original);
        await upload(file, original, preserve: false);
        final sent = adapter.bodies.last,
            src = image.decodeJpg(original)!,
            dst = image.decodeJpg(sent)!;
        expect(sent.take(2), [0xff, 0xd8]);
        expect(presigns.last['contentType'], 'image/jpeg');
        expect(sent.length, lessThan(original.length));
        expect((dst.width, dst.height), (src.width, src.height));
        var error = 0.0, samples = 0;
        for (var y = 0; y < src.height; y += 8) {
          for (var x = 0; x < src.width; x += 8) {
            final a = src.getPixel(x, y), b = dst.getPixel(x, y);
            error += (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
            samples += 3;
          }
        }
        final mean = error / samples;
        expect(mean, lessThan(8));
        if (orientation == 6) {
          print(
              'Synthetic JPEG orientation 6: ${original.length} -> ${sent.length} bytes; sampled RGB mean error $mean');
        }
      }
      final png = _png(), pngFile = await source('transparent.png', png);
      await upload(pngFile, png, preserve: false);
      final pngSent = adapter.bodies.last;
      expect(presigns.last['contentType'], 'image/png');
      expect(pngSent.length, lessThan(png.length));
      expect(await _rgba(pngSent), orderedEquals(await _rgba(png)));
      print(
          'Synthetic RGBA QR-like PNG: ${png.length} -> ${pngSent.length} bytes; pixels exact');
      await upload(pngFile, png, preserve: true);
      expect(adapter.bodies.last, orderedEquals(png));
      final originalJpg = await files.first.readAsBytes();
      await upload(files.first, originalJpg, preserve: true);
      expect(adapter.bodies.last, orderedEquals(originalJpg));
      final marker = ascii.encode('ICC_PROFILE\u0000');
      final unsupported = Uint8List.fromList([
        ...originalJpg.take(2),
        0xff,
        0xe2,
        0,
        marker.length + 2,
        ...marker,
        ...originalJpg.skip(2)
      ]);
      final iccFile = await source('unsupported.jpg', unsupported);
      await upload(iccFile, unsupported, preserve: false);
      expect(adapter.bodies.last, orderedEquals(unsupported));
      final apng = _png(animated: true),
          apngFile = await source('animated.png', apng);
      await upload(apngFile, apng, preserve: false);
      expect(adapter.bodies.last, orderedEquals(apng));
      final controller =
          ChatAttachmentsController(service, GlobalCache(), client);
      final forward = LocalAttach(
          path: files.first.path,
          name: 'forward.jpg',
          mimeType: 'image/jpeg',
          size: originalJpg.length,
          isImage: true,
          preserveOriginal: true);
      expect(controller.add(forward), isTrue);
      final index = adapter.bodies.length;
      final priorConfirms = confirms;
      adapter.failNext = true;
      await controller.upload(forward, chatId: 'chat');
      expect(adapter.bodies[index], orderedEquals(originalJpg));
      expect(controller.pending.single.isFailed, isTrue);
      expect(controller.pending.single.preserveOriginal, isTrue);
      expect(confirms, priorConfirms);
      expect(saves, 0);
      await controller.retry(controller.pending.single, chatId: 'chat');
      expect(adapter.bodies[index + 1], orderedEquals(originalJpg));
      for (final attempt in [index, index + 1]) {
        expect(presigns[attempt]['fileName'], 'forward.jpg');
        expect(presigns[attempt]['contentType'], 'image/jpeg');
        expect(presigns[attempt]['fileSize'], originalJpg.length);
      }
      expect(confirms, priorConfirms + 1);
      expect(controller.pending.single.preserveOriginal, isTrue);
      expect(controller.pending.single.isUploaded, isTrue);
      expect(saves, 1);
      expect(savedRows.single['p_file_name'], 'forward.jpg');
      expect(savedRows.single['p_file_type'], 'image/jpeg');
      expect(savedRows.single['p_file_size'], originalJpg.length);
      expect(savedRows.single['p_file_key'], 'chats/test/object');
      expect(await files.first.readAsBytes(), orderedEquals(originalJpg));
      if (const bool.fromEnvironment('CHAT_ATTACHMENT_SESSION_FENCE_QA')) {
        // Direct legacy restore can replace pending with a new object while
        // presign is waiting. That must not dispatch the stale object's PUT.
        final replacedPath = await source('replaced.jpg', originalJpg);
        final mutationController =
            ChatAttachmentsController(service, GlobalCache(), client);
        final replaced = LocalAttach(
            path: replacedPath.path,
            name: 'replaced.jpg',
            mimeType: 'image/jpeg',
            size: originalJpg.length,
            isImage: true,
            preserveOriginal: true);
        expect(mutationController.add(replaced), isTrue);
        presignEntered = Completer<void>();
        presignRelease = Completer<void>();
        final released = presignRelease!;
        final beforeReplacementPuts = adapter.bodies.length;
        final work = mutationController.upload(replaced, chatId: 'chat');
        await presignEntered!.future;
        mutationController.pending[0] =
            mutationController.pending[0].copyWith();
        released.complete();
        await work;
        expect(adapter.bodies.length, beforeReplacementPuts,
            reason: 'replacement during presign must prevent the stale PUT');
        expect(await replacedPath.readAsBytes(), orderedEquals(originalJpg));
        mutationController.dispose();

        // Once PUT is already in flight it cannot be undone; a replaced entry
        // must nevertheless prevent subsequent confirm and save dispatch.
        final putPath = await source('during-put.jpg', originalJpg);
        final putController =
            ChatAttachmentsController(service, GlobalCache(), client);
        final putFile = LocalAttach(
            path: putPath.path,
            name: 'during-put.jpg',
            mimeType: 'image/jpeg',
            size: originalJpg.length,
            isImage: true,
            preserveOriginal: true);
        expect(putController.add(putFile), isTrue);
        adapter.putEntered = Completer<void>();
        adapter.putRelease = Completer<void>();
        final releasePut = adapter.putRelease!;
        final beforeConfirm = confirms, beforeSaves = saves;
        final putWork = putController.upload(putFile, chatId: 'chat');
        await adapter.putEntered!.future;
        putController.pending[0] = putController.pending[0].copyWith();
        releasePut.complete();
        await putWork;
        expect(confirms, beforeConfirm);
        expect(saves, beforeSaves);
        expect(await putPath.readAsBytes(), orderedEquals(originalJpg));
        putController.dispose();
        // Use a distinct file path because the controller deduplicates paths.
        final oldPath = await source('owner-a.jpg', originalJpg);
        final pendingA = LocalAttach(
            path: oldPath.path,
            name: 'owner-a.jpg',
            mimeType: 'image/jpeg',
            size: originalJpg.length,
            isImage: true,
            preserveOriginal: true);
        expect(controller.add(pendingA), isTrue);
        adapter.failNext = true;
        await controller.upload(pendingA, chatId: 'chat');
        expect(controller.pending.last.isFailed, isTrue);
        await client.auth.setInitialSession(
            _session('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'));
        await Future<void>.delayed(Duration.zero);
        final priorRequests = presigns.length;
        await controller.retry(controller.pending.last, chatId: 'chat');
        expect(presigns.length, priorRequests,
            reason: 'old owner attachment must never upload as new owner');
        final callsAtSwitch = totalHttp, putsAtSwitch = adapter.bodies.length;
        controller.remove(pendingA);
        controller.clear();
        await controller.deleteUploaded('synthetic-file-id');
        expect(controller.pending.any((f) => f.localId == pendingA.localId),
            isTrue);
        expect(await oldPath.readAsBytes(), orderedEquals(originalJpg));
        expect(totalHttp, callsAtSwitch);
        await client.auth.setInitialSession(_session(uid));
        await Future<void>.delayed(Duration.zero);
        await controller.retry(controller.pending.last, chatId: 'chat');
        expect(totalHttp, callsAtSwitch,
            reason: 'A→B→A cannot revalidate the old controller');
        expect(adapter.bodies.length, putsAtSwitch);
        controller.dispose();

        // A new controller bound to A must also reject same-UID SID rotation.
        final sidController =
            ChatAttachmentsController(service, GlobalCache(), client);
        final sidFile = LocalAttach(
            path: oldPath.path,
            name: 'owner-a.jpg',
            mimeType: 'image/jpeg',
            size: originalJpg.length,
            isImage: true,
            preserveOriginal: true);
        expect(sidController.add(sidFile), isTrue);
        adapter.failNext = true;
        await sidController.upload(sidFile, chatId: 'chat');
        expect(sidController.pending.single.isFailed, isTrue);
        await client.auth.setInitialSession(
            _session(uid, sid: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'));
        await Future<void>.delayed(Duration.zero);
        final callsAtSidChange = totalHttp;
        await sidController.retry(sidController.pending.single, chatId: 'chat');
        await sidController.deleteUploaded('synthetic-file-id');
        expect(totalHttp, callsAtSidChange);
        expect(sidController.pending.single.isFailed, isTrue);
        expect(await oldPath.readAsBytes(), orderedEquals(originalJpg));
        sidController.dispose();

        // Direct pending restoration is fenced too; a fresh credential object for
        // the same UID/SID cannot silently rebind an existing controller.
        final tokenController =
            ChatAttachmentsController(service, GlobalCache(), client);
        final restored = LocalAttach(
            path: oldPath.path,
            name: 'restored.jpg',
            mimeType: 'image/jpeg',
            size: originalJpg.length,
            isImage: true,
            preserveOriginal: true);
        tokenController.pending.add(restored);
        await client.auth.setInitialSession(_session(uid,
            sid: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            refresh: 'rotated-refresh'));
        await Future<void>.delayed(Duration.zero);
        final callsAtRotation = totalHttp;
        await tokenController.upload(restored, chatId: 'chat');
        expect(totalHttp, callsAtRotation);
        expect(tokenController.pending.single.localId, restored.localId);
        tokenController.dispose();
      } else {
        // The shipped baseline must continue to retry after a normal same-SID
        // token refresh; the exact-session fence remains QA-only until rebind.
        final refreshPath =
            await source('same-session-refresh.jpg', originalJpg);
        final refreshFile = LocalAttach(
            path: refreshPath.path,
            name: 'same-session-refresh.jpg',
            mimeType: 'image/jpeg',
            size: originalJpg.length,
            isImage: true,
            preserveOriginal: true);
        expect(controller.add(refreshFile), isTrue);
        adapter.failNext = true;
        await controller.upload(refreshFile, chatId: 'chat');
        expect(controller.pending.last.isFailed, isTrue);
        await client.auth
            .setInitialSession(_session(uid, refresh: 'new-refresh'));
        await Future<void>.delayed(Duration.zero);
        final count = presigns.length;
        await controller.retry(controller.pending.last, chatId: 'chat');
        expect(presigns.length, count + 1);
        expect(adapter.bodies.last, orderedEquals(originalJpg));
        expect(controller.pending.last.isUploaded, isTrue);
        controller.dispose();
      }
    } finally {
      service.dispose();
      dio.close(force: true);
      for (final f in files) {
        if (await f.exists()) await f.delete();
      }
      await dir.delete();
      unawaited(client.dispose());
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
