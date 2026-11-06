import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image/image.dart' as image;

var _photoWorkerActive = false;

/// Opt-in only. Unsupported metadata or image structure is kept unchanged.
Future<Uint8List> optimizeChatPhoto(Uint8List bytes,
    {CancelToken? cancelToken}) async {
  if (bytes.length > 10 * 1024 * 1024 ||
      bytes.length < 128 ||
      (cancelToken?.isCancelled ?? false) ||
      _photoWorkerActive) return bytes;
  _photoWorkerActive = true;
  final port = ReceivePort();
  final exitPort = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
        _worker,
        [
          port.sendPort,
          TransferableTypedData.fromList([bytes])
        ],
        onError: port.sendPort,
        onExit: exitPort.sendPort);
    final result = await Future.any<Object?>([
      port.first,
      Future<void>.delayed(const Duration(seconds: 15)),
      if (cancelToken != null) cancelToken.whenCancel.then((_) => null),
    ]);
    if (result is TransferableTypedData &&
        !(cancelToken?.isCancelled ?? false)) {
      final data = result.materialize().asUint8List();
      if (data.length < bytes.length) return data;
    }
  } catch (_) {
    // Unsupported or corrupt input stays byte-for-byte unchanged.
  } finally {
    worker?.kill(priority: Isolate.immediate);
    port.close();
    if (worker == null) {
      exitPort.close();
      _photoWorkerActive = false;
    } else {
      // Wait for actual termination before allowing another large decode.
      final terminated = exitPort.first.then((_) {
        exitPort.close();
        _photoWorkerActive = false;
      });
      await Future.any<void>([
        terminated,
        Future<void>.delayed(const Duration(seconds: 1)),
      ]);
    }
  }
  return bytes;
}

void _worker(List<Object> args) {
  final port = args[0] as SendPort;
  try {
    final bytes =
        (args[1] as TransferableTypedData).materialize().asUint8List();
    final result = _encode(bytes);
    port.send(result == null ? null : TransferableTypedData.fromList([result]));
  } catch (_) {
    port.send(null);
  }
}

// Baseline JFIF with a structurally valid EXIF is supported. The result keeps
// only orientation; all other EXIF (including location) is intentionally lost.
// ICC, XMP, unknown metadata, maker notes and signatures fall back unchanged.
Uint8List? _encode(Uint8List input) {
  if (input[0] != 0xff || input[1] != 0xd8) return null;
  var p = 2;
  var width = 0, height = 0, scans = 0;
  var ended = false;
  Uint8List? jfif;
  int? orientation;
  var sawExif = false;
  var exifStart = -1, exifEnd = -1;
  while (p + 2 <= input.length) {
    if (input[p++] != 0xff) return null;
    while (p < input.length && input[p] == 0xff) {
      p++;
    }
    if (p >= input.length) return null;
    final marker = input[p++];
    if (marker == 0xd9) {
      if (p != input.length || scans != 1) return null;
      ended = true;
      break;
    }
    if (p + 2 > input.length) return null;
    final length = (input[p] << 8) | input[p + 1];
    if (length < 2 || p + length > input.length) return null;
    if (marker >= 0xe0 && marker <= 0xef) {
      if (marker == 0xe1) {
        if (sawExif) return null;
        sawExif = true;
        exifStart = p - 2;
        exifEnd = p + length;
        orientation = _readOrientation(input.sublist(p + 2, p + length));
        if (orientation == null) return null;
      } else if (marker == 0xe0) {
        if (length != 16 ||
            jfif != null ||
            input[p + 14] != 0 ||
            input[p + 15] != 0 ||
            String.fromCharCodes(input.sublist(p + 2, p + 7)) != 'JFIF\x00')
          return null;
        jfif = Uint8List.fromList(input.sublist(p - 2, p + length));
      } else {
        return null;
      }
    } else if (!const {0xc0, 0xc4, 0xdb, 0xdd, 0xda}.contains(marker)) {
      return null;
    }
    if (marker == 0xc0) {
      if (length != 17 || input[p + 2] != 8 || input[p + 7] != 3 || width != 0)
        return null;
      height = (input[p + 3] << 8) | input[p + 4];
      width = (input[p + 5] << 8) | input[p + 6];
      if (width == 0 || height == 0 || width * height > 16000000) return null;
    }
    p += length;
    if (marker == 0xda) {
      if (++scans != 1 || width == 0) return null;
      while (p + 1 < input.length) {
        if (input[p++] != 0xff) continue;
        final next = input[p];
        if (next == 0 || (next >= 0xd0 && next <= 0xd7)) {
          p++;
          continue;
        }
        p--;
        break;
      }
    }
  }
  if (!ended || p != input.length || scans != 1 || jfif == null) return null;
  // image.decodeJpg bakes EXIF orientation automatically. Decode without APP1
  // and retain the orientation tag on the output to avoid rotating twice.
  final decodeBytes = sawExif
      ? (BytesBuilder(copy: false)
            ..add(Uint8List.sublistView(input, 0, exifStart))
            ..add(Uint8List.sublistView(input, exifEnd)))
          .takeBytes()
      : input;
  final decoded = image.decodeJpg(decodeBytes);
  if (decoded == null || decoded.width != width || decoded.height != height)
    return null;
  final longest = width > height ? width : height;
  final resized = longest > 2048
      ? image.copyResize(decoded,
          width: (width * 2048 / longest).round(),
          height: (height * 2048 / longest).round(),
          interpolation: image.Interpolation.linear)
      : decoded;
  resized.exif = image.ExifData();
  if (orientation != null) resized.exif.imageIfd.orientation = orientation;
  final encoded =
      image.encodeJpg(resized, quality: 88, chroma: image.JpegChroma.yuv444);
  // Keep JFIF density metadata exactly; reject an unexpected encoder layout.
  if (encoded.length < 20 ||
      encoded[2] != 0xff ||
      encoded[3] != 0xe0 ||
      encoded[4] != 0 ||
      encoded[5] != 16) return null;
  final output = (BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(encoded, 0, 2))
        ..add(jfif)
        ..add(Uint8List.sublistView(encoded, 20)))
      .takeBytes();
  return output.length < input.length ? output : null;
}

// EXIF/TIFF offsets are relative to the TIFF header, not the JPEG file.
// Validate all linked IFDs and value spans before retaining just orientation.
int? _readOrientation(Uint8List bytes) {
  if (bytes.length < 14 ||
      String.fromCharCodes(bytes.sublist(0, 6)) != 'Exif\x00\x00') return null;
  final data = ByteData.sublistView(bytes, 6);
  final little = data.getUint16(0) == 0x4949;
  if (!little && data.getUint16(0) != 0x4d4d) return null;
  final endian = little ? Endian.little : Endian.big;
  if (data.getUint16(2, endian) != 42) return null;
  final queue = <int>[data.getUint32(4, endian)];
  final visited = <int>{};
  int? orientation;
  var totalEntries = 0;
  const sizes = <int, int>{
    1: 1,
    2: 1,
    3: 2,
    4: 4,
    5: 8,
    6: 1,
    7: 1,
    8: 2,
    9: 4,
    10: 8,
    11: 4,
    12: 8
  };
  while (queue.isNotEmpty) {
    final offset = queue.removeLast();
    if (offset < 8 ||
        offset + 2 > data.lengthInBytes ||
        !visited.add(offset) ||
        visited.length > 16) return null;
    final count = data.getUint16(offset, endian);
    totalEntries += count;
    final end = offset + 2 + count * 12;
    if (totalEntries > 512 || end + 4 > data.lengthInBytes) return null;
    for (var i = 0; i < count; i++) {
      final entry = offset + 2 + i * 12;
      final tag = data.getUint16(entry, endian);
      final type = data.getUint16(entry + 2, endian);
      final number = data.getUint32(entry + 4, endian);
      final size = sizes[type];
      if (size == null || number > data.lengthInBytes || tag == 0x927c)
        return null;
      final length = number * size;
      if (length > data.lengthInBytes) return null;
      if (length > 4) {
        final valueOffset = data.getUint32(entry + 8, endian);
        if (valueOffset > data.lengthInBytes - length) return null;
      }
      if (tag == 0x0112) {
        if (type != 3 || number != 1 || orientation != null) return null;
        orientation = data.getUint16(entry + 8, endian);
        if (orientation < 1 || orientation > 8) return null;
      }
      if (tag == 0x8769 || tag == 0x8825 || tag == 0xa005) {
        if (type != 4 || number != 1) return null;
        final next = data.getUint32(entry + 8, endian);
        if (next == 0) return null;
        queue.add(next);
      }
    }
    final next = data.getUint32(end, endian);
    if (next != 0) queue.add(next);
  }
  return orientation ?? 1;
}
