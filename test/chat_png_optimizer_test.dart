import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart' show getCrc32;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:student_platform/src/services/chat_png_optimizer.dart';
import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Uint8List _chunk(String name, List<int> bytes) {
  final type = ascii.encode(name);
  final header = ByteData(4)..setUint32(0, bytes.length);
  final crc = ByteData(4)..setUint32(0, getCrc32([...type, ...bytes]));
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...type,
    ...bytes,
    ...crc.buffer.asUint8List()
  ]);
}

Uint8List _png(
    {int depth = 8,
    bool interlaced = false,
    bool animated = false,
    bool unsafeChunk = false,
    bool badFilter = false}) {
  const width = 256, height = 256;
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height);
  header.setUint8(8, depth);
  header.setUint8(9, 6);
  header.setUint8(12, interlaced ? 1 : 0);
  final raw = BytesBuilder(copy: false);
  final passes = interlaced
      ? const [
          [0, 0, 8, 8],
          [4, 0, 8, 8],
          [0, 4, 4, 8],
          [2, 0, 4, 4],
          [0, 2, 2, 4],
          [1, 0, 2, 2],
          [0, 1, 1, 2]
        ]
      : const [
          [0, 0, 1, 1]
        ];
  for (final p in passes) {
    for (var y = p[1]; y < height; y += p[3]) {
      raw.addByte(badFilter ? 5 : 0);
      for (var x = p[0]; x < width; x += p[2]) {
        final black = ((x ~/ 8 + y ~/ 8) % 2) == 0;
        final c = black ? 0 : 255;
        for (final channel in [c, c, c, (x < 64 ? 0 : 255)]) {
          raw.addByte(channel);
          if (depth == 16) raw.addByte(channel);
        }
      }
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
    ..._chunk('tEXt', ascii.encode('Comment\x00preserved')),
    if (unsafeChunk) ..._chunk('dSIG', [1, 2, 3]),
    if (animated) ..._chunk('acTL', [0, 0, 0, 1, 0, 0, 0, 0]),
    ..._chunk('IDAT', ZLibEncoder(level: 0).convert(raw.takeBytes())),
    ..._chunk('IEND', []),
  ]);
}

Future<Uint8List> _pixels(Uint8List data) async {
  final codec = await ui.instantiateImageCodec(data);
  final frame = await codec.getNextFrame();
  final pixels =
      await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  return pixels!.buffer.asUint8List();
}

class _Adapter implements HttpClientAdapter {
  final bodies = <Uint8List>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final bytes = BytesBuilder();
    if (requestStream != null)
      await for (final chunk in requestStream) {
        bytes.add(chunk);
      }
    bodies.add(bytes.takeBytes());
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}

String _session(String uid) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return jsonEncode({
    'access_token': '${part({'alg': 'HS256'})}.${part({
          'sub': uid,
          'exp': now + 3600
        })}.sig',
    'refresh_token': 'refresh-$uid',
    'token_type': 'bearer',
    'expires_in': 3600,
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
  test('explicit JPEG photo uses actual uploaded bytes while file preserves source', () async {
    final photo = image.Image(width: 640, height: 480);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        photo.setPixelRgb(x, y, (x ~/ 3) % 256, (y ~/ 2) % 256, ((x + y) ~/ 5) % 256);
      }
    }
    final original = image.encodeJpg(photo, quality: 98);
    final dir = await Directory.systemTemp.createTemp('chat_photo_upload_');
    final file = File('${dir.path}/photo.jpg');
    await file.writeAsBytes(original);
    final requests = <Map<String, dynamic>>[];
    final client = SupabaseClient('https://example.invalid', 'qa',
        httpClient: MockClient((request) async {
      if (request.url.path.endsWith('generate-upload-url')) {
        requests.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        return http.Response(jsonEncode({
          'uploadUrl': 'https://upload.invalid/object',
          'fileKey': 'chats/test/object',
          'fileUrl': 'https://example.invalid/object',
          'headers': <String, String>{}
        }), 200, headers: {'content-type': 'application/json'}, request: request);
      }
      return http.Response('{"confirmed":true}', 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await client.auth.setInitialSession(_session('a'));
    final adapter = _Adapter(), dio = Dio()..httpClientAdapter = adapter;
    final service = FileService(supabase: client, dio: dio);
    final compressed = await service.uploadFileToChat(
        file: file, chatId: 'chat', messageId: '', uploadedBy: 'a', preserveOriginal: false);
    expect(compressed.fileType, 'image/jpeg');
    expect(compressed.fileName, 'photo.jpg');
    expect(compressed.fileSize, adapter.bodies[0].length);
    expect(compressed.fileSize, lessThan(original.length));
    expect(requests[0]['fileSize'], compressed.fileSize);
    expect(requests[0]['contentType'], 'image/jpeg');
    expect(await file.readAsBytes(), orderedEquals(original));
    final asFile = await service.uploadFile(file: file, chatId: 'chat');
    expect(asFile.success, isTrue);
    expect(adapter.bodies[1], orderedEquals(original));
    expect(asFile.fileSize, original.length);
    service.dispose();
    dio.close(force: true);
    await client.dispose();
    await file.delete();
    await dir.delete();
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('retry keeps forward original flag', () {
    final item = LocalAttach(
        path: 'p',
        name: 'a.png',
        mimeType: 'image/png',
        size: 1,
        isImage: true,
        preserveOriginal: true);
    expect(
        item
            .copyWith(uploadStatus: LocalAttachUploadStatus.failed)
            .preserveOriginal,
        true);
  });
  for (final depth in [8, 16]) {
    for (final interlaced in [false, true]) {
      test(
          'PNG depth=$depth interlaced=$interlaced preserves pixels and metadata',
          () async {
        final original = _png(depth: depth, interlaced: interlaced);
        final candidate = await optimizePngLosslessly(original);
        expect(candidate, isNotNull);
        expect(candidate!.length, lessThan(original.length));
        expect(await _pixels(candidate), await _pixels(original));
        expect(latin1.decode(candidate, allowInvalid: true),
            contains('preserved'));
      });
    }
  }
  test('animated, corrupt, malformed and non-PNG stay unchanged', () async {
    final corrupt = _png()..[30] ^= 1;
    for (final bytes in [
      _png(animated: true),
      _png(unsafeChunk: true),
      corrupt,
      _png(badFilter: true),
      Uint8List.fromList(List.filled(100, 42))
    ]) {
      expect(await optimizePngLosslessly(bytes), isNull);
      expect(await optimizeNewChatPng(bytes), bytes);
    }
  });
  test('isolate result is lossless and cancellation returns source', () async {
    final original = _png();
    final candidate = await optimizeNewChatPng(original);
    expect(candidate.length, lessThan(original.length));
    expect(await _pixels(candidate), await _pixels(original));
    final token = CancelToken();
    final pending = optimizeNewChatPng(original, cancelToken: token);
    token.cancel();
    expect(await pending, original);
  });

  test(
      'both chat upload APIs use actual bytes, size and PNG MIME; preserve-original bypasses',
      () async {
    final dir = await Directory.systemTemp.createTemp('chat_png_upload_');
    final original = _png();
    final file = File('${dir.path}/photo.png');
    await file.writeAsBytes(original);
    final requests = <Map<String, dynamic>>[];
    final client = SupabaseClient('https://example.invalid', 'qa',
        httpClient: MockClient((request) async {
      if (request.url.path.endsWith('generate-upload-url')) {
        requests
            .add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        return http.Response(
            jsonEncode({
              'uploadUrl': 'https://upload.invalid/object',
              'fileKey': 'chats/test/object',
              'fileUrl': 'https://example.invalid/object',
              'headers': <String, String>{}
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request);
      }
      return http.Response('{"confirmed":true}', 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    await client.auth.setInitialSession(_session('a'));
    final adapter = _Adapter(), dio = Dio()..httpClientAdapter = adapter;
    final service = FileService(supabase: client, dio: dio);
    final saved = await service.uploadFileToChat(
        file: file,
        chatId: 'chat',
        messageId: '',
        uploadedBy: 'a',
        preserveOriginal: false);
    expect(saved.fileName, 'photo.png');
    expect(saved.fileType, 'image/png');
    expect(saved.fileSize, adapter.bodies[0].length);
    expect(saved.fileSize, lessThan(original.length));
    expect(requests[0]['fileSize'], saved.fileSize);
    expect(requests[0]['contentType'], 'image/png');
    expect(await _pixels(adapter.bodies[0]), await _pixels(original));
    final forwarded = await service.uploadFile(
        file: file, chatId: 'chat', preserveOriginal: true);
    expect(forwarded.success, true);
    expect(adapter.bodies[1], original);
    expect(forwarded.fileSize, original.length);
    expect(requests[1]['fileSize'], original.length);
    final cancelled = CancelToken()..cancel();
    final result = await service.uploadFile(
        file: file, chatId: 'chat', cancelToken: cancelled);
    expect(result.success, false);
    expect(requests.length, 2);
    service.dispose();
    dio.close(force: true);
    await client.dispose();
    await file.delete();
    await dir.delete();
  });

  test('session switch while presign is pending never uploads under new owner',
      () async {
    final dir = await Directory.systemTemp.createTemp('chat_png_owner_');
    final file = File('${dir.path}/photo.png');
    await file.writeAsBytes(_png());
    final entered = Completer<void>(), release = Completer<void>();
    final client = SupabaseClient('https://example.invalid', 'qa',
        httpClient: MockClient((request) async {
      entered.complete();
      await release.future;
      return http.Response(
          jsonEncode({
            'uploadUrl': 'https://upload.invalid/object',
            'fileKey': 'chats/test/object',
            'fileUrl': 'https://example.invalid/object',
            'headers': <String, String>{}
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request);
    }));
    await client.auth.setInitialSession(_session('a'));
    final adapter = _Adapter(), dio = Dio()..httpClientAdapter = adapter;
    final service = FileService(supabase: client, dio: dio);
    final pending =
        service.uploadFile(file: file, chatId: 'chat', preserveOriginal: false);
    await entered.future;
    await client.auth.setInitialSession(_session('b'));
    release.complete();
    expect((await pending).success, false);
    expect(adapter.bodies, isEmpty);
    service.dispose();
    dio.close(force: true);
    await client.dispose();
    await file.delete();
    await dir.delete();
  });

  for (final action in ['switch', 'cancel']) {
    test('$action while confirmation is pending cannot report success',
        () async {
      final dir = await Directory.systemTemp.createTemp('chat_png_confirm_');
      final file = File('${dir.path}/photo.png');
      await file.writeAsBytes(_png());
      final entered = Completer<void>(), release = Completer<void>();
      final client = SupabaseClient('https://example.invalid', 'qa',
          httpClient: MockClient((request) async {
        if (request.url.path.endsWith('generate-upload-url')) {
          return http.Response(
              jsonEncode({
                'uploadUrl': 'https://upload.invalid/object',
                'fileKey': 'chats/test/object',
                'fileUrl': 'https://example.invalid/object',
                'headers': <String, String>{}
              }),
              200,
              headers: {'content-type': 'application/json'},
              request: request);
        }
        entered.complete();
        await release.future;
        return http.Response('{"confirmed":true}', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }));
      await client.auth.setInitialSession(_session('a'));
      final adapter = _Adapter(), dio = Dio()..httpClientAdapter = adapter;
      final service = FileService(supabase: client, dio: dio),
          token = CancelToken();
      final pending = service.uploadFile(
          file: file,
          chatId: 'chat',
          preserveOriginal: false,
          cancelToken: token);
      await entered.future;
      if (action == 'switch') {
        await client.auth.setInitialSession(_session('b'));
      } else {
        token.cancel();
      }
      release.complete();
      expect((await pending).success, false);
      expect(adapter.bodies.length, 1);
      service.dispose();
      dio.close(force: true);
      await client.dispose();
      await file.delete();
      await dir.delete();
    });
  }
}
