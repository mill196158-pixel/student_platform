import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

const _signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
const _maxInput = 10 * 1024 * 1024;
const _maxRaw = 16 * 1024 * 1024;

/// Optimises only safe static PNGs. A failed or unprofitable attempt returns
/// the original bytes; cancellation never starts an upload.
Future<Uint8List> optimizeNewChatPng(Uint8List original,
    {CancelToken? cancelToken}) async {
  if (original.length > _maxInput ||
      original.length < 64 ||
      (cancelToken?.isCancelled ?? false)) return original;
  final port = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
        _worker,
        [
          port.sendPort,
          TransferableTypedData.fromList([original])
        ],
        onError: port.sendPort,
        onExit: port.sendPort);
    if (cancelToken?.isCancelled ?? false) return original;
    final result = await Future.any<Object?>([
      port.first,
      Future<void>.delayed(const Duration(seconds: 6)),
      if (cancelToken != null) cancelToken.whenCancel.then((_) => null),
    ]);
    if (result is TransferableTypedData) {
      final candidate = result.materialize().asUint8List();
      if (candidate.length < original.length) return candidate;
    }
    return original;
  } catch (_) {
    return original;
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _worker(List<Object> args) async {
  final port = args[0] as SendPort;
  try {
    final input =
        (args[1] as TransferableTypedData).materialize().asUint8List();
    final output = await optimizePngLosslessly(input);
    port.send(output == null ? null : TransferableTypedData.fromList([output]));
  } catch (_) {
    port.send(null);
  }
}

int _u32(Uint8List data, int offset) =>
    ByteData.sublistView(data).getUint32(offset);

/// Internal test seam. Preserves PNG metadata/chunks and compressed scanlines.
@visibleForTesting
Future<Uint8List?> optimizePngLosslessly(Uint8List input) async {
  if (input.length < 64 || input.length > _maxInput) return null;
  for (var i = 0; i < _signature.length; i++) {
    if (input[i] != _signature[i]) return null;
  }
  var offset = 8, count = 0, sawData = false, endedData = false, sawEnd = false;
  var palette = false,
      colorType = -1,
      width = 0,
      height = 0,
      depth = 0,
      interlace = 0;
  var firstData = -1, afterData = -1;
  final idat = BytesBuilder(copy: false);
  while (offset + 12 <= input.length) {
    final length = _u32(input, offset);
    if (length > _maxInput ||
        offset + 12 + length > input.length ||
        ++count > 2048) return null;
    final typeBytes = input.sublist(offset + 4, offset + 8);
    if (typeBytes.any((c) => !((c >= 65 && c <= 90) || (c >= 97 && c <= 122))))
      return null;
    final type = String.fromCharCodes(typeBytes);
    final end = offset + 12 + length;
    if (getCrc32(input.sublist(offset + 4, offset + 8 + length)) !=
        _u32(input, offset + 8 + length)) return null;
    if (count == 1) {
      if (type != 'IHDR' || length != 13) return null;
      width = _u32(input, offset + 8);
      height = _u32(input, offset + 12);
      depth = input[offset + 16];
      colorType = input[offset + 17];
      interlace = input[offset + 20];
      if (width == 0 ||
          height == 0 ||
          width > 8192 ||
          height > 8192 ||
          input[offset + 18] != 0 ||
          input[offset + 19] != 0 ||
          interlace > 1) return null;
      const validDepths = <int, List<int>>{
        0: [1, 2, 4, 8, 16],
        2: [8, 16],
        3: [1, 2, 4, 8],
        4: [8, 16],
        6: [8, 16]
      };
      if (!(validDepths[colorType]?.contains(depth) ?? false)) return null;
    } else if (type == 'IHDR') {
      return null;
    }
    if (type == 'acTL' || type == 'fcTL' || type == 'fdAT') return null;
    // Unknown unsafe-to-copy ancillary chunks can depend on the original
    // compressed stream (for example file signatures). Keep the source.
    const knownSemanticChunks = {
      'gAMA',
      'cHRM',
      'sRGB',
      'iCCP',
      'sBIT',
      'tRNS',
      'bKGD',
      'hIST',
      'sPLT'
    };
    if ((typeBytes[0] & 32) != 0 &&
        (typeBytes[3] & 32) == 0 &&
        !knownSemanticChunks.contains(type)) return null;
    if (type == 'PLTE') {
      if (sawData ||
          palette ||
          colorType == 0 ||
          colorType == 4 ||
          length == 0 ||
          length % 3 != 0 ||
          length > 768 ||
          (colorType == 3 && length ~/ 3 > (1 << depth))) return null;
      palette = true;
    }
    if (type == 'IDAT') {
      if (endedData || sawEnd) return null;
      firstData = firstData < 0 ? offset : firstData;
      sawData = true;
      afterData = end;
      idat.add(input.sublist(offset + 8, offset + 8 + length));
    } else if (sawData) {
      endedData = true;
    }
    if (type == 'IEND') {
      if (!sawData || length != 0 || end != input.length) return null;
      sawEnd = true;
      offset = end;
      break;
    }
    if ((typeBytes[0] & 32) == 0 &&
        !const {'IHDR', 'PLTE', 'IDAT', 'IEND'}.contains(type)) return null;
    offset = end;
  }
  if (!sawEnd || (colorType == 3 && !palette)) return null;
  final channels = const {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colorType]!;
  final passes = interlace == 0
      ? const [
          [0, 0, 1, 1]
        ]
      : const [
          [0, 0, 8, 8],
          [4, 0, 8, 8],
          [0, 4, 4, 8],
          [2, 0, 4, 4],
          [0, 2, 2, 4],
          [1, 0, 2, 2],
          [0, 1, 1, 2]
        ];
  var expected = 0;
  final rowLengths = <(int, int)>[];
  for (final p in passes) {
    final w = width <= p[0] ? 0 : (width - p[0] + p[2] - 1) ~/ p[2];
    final h = height <= p[1] ? 0 : (height - p[1] + p[3] - 1) ~/ p[3];
    if (w == 0 || h == 0) continue;
    final row = (w * channels * depth + 7) ~/ 8 + 1;
    expected += row * h;
    if (expected > _maxRaw) return null;
    rowLengths.add((row, h));
  }
  final raw = BytesBuilder(copy: false);
  var received = 0;
  try {
    await for (final bytes
        in Stream<List<int>>.value(idat.takeBytes()).transform(ZLibDecoder())) {
      received += bytes.length;
      if (received > expected || received > _maxRaw) return null;
      raw.add(bytes);
    }
  } catch (_) {
    return null;
  }
  if (received != expected) return null;
  final scanlines = raw.takeBytes();
  var cursor = 0;
  for (final pass in rowLengths) {
    for (var row = 0; row < pass.$2; row++) {
      if (scanlines[cursor] > 4) return null;
      cursor += pass.$1;
    }
  }
  final compressed = ZLibEncoder(level: 9).convert(scanlines);
  final header = ByteData(8)..setUint32(0, compressed.length);
  header.buffer.asUint8List().setRange(4, 8, const [73, 68, 65, 84]);
  final checksum = ByteData(4)
    ..setUint32(
        0,
        getCrc32([
          ...const [73, 68, 65, 84],
          ...compressed
        ]));
  final output = BytesBuilder(copy: false)
    ..add(input.sublist(0, firstData))
    ..add(header.buffer.asUint8List())
    ..add(compressed)
    ..add(checksum.buffer.asUint8List())
    ..add(input.sublist(afterData));
  final candidate = output.takeBytes();
  return candidate.length < input.length ? candidate : null;
}
