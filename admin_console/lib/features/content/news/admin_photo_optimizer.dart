import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'admin_photo_optimizer_stub.dart'
    if (dart.library.html) 'admin_photo_optimizer_web.dart'
    as legacy;
import 'admin_alpha_optimizer_stub.dart'
    if (dart.library.html) 'admin_alpha_optimizer_web.dart' as alpha;

/// Optimise only simple static PNGs, preserving every decoded RGBA pixel.
/// JPEG, WebP, animations, metadata and uncertain input remain untouched.
Future<Uint8List?> optimizeAdminPhoto(Uint8List original) =>
    compute(_optimise, Uint8List.fromList(original));

/// Compatibility for previously accepted oversized JPEGs on Admin Web.
/// This is lossy and does not guarantee preservation of QR codes or fine text.
Future<Uint8List?> optimizeLargeJpegLegacy(Uint8List original) =>
    legacy.optimizeAdminPhoto(Uint8List.fromList(original));

Future<Uint8List?> optimizeAdminJpegBudget(Uint8List original,
    {Listenable? invalidation, bool Function()? isCurrent}) =>
    legacy.optimizeAdminPhoto(Uint8List.fromList(original), targetBudget: true,
        invalidation: invalidation, isCurrent: isCurrent);

Future<Uint8List?> optimizeAdminAlpha(Uint8List original,
    {Listenable? invalidation, bool Function()? isCurrent}) =>
    alpha.optimizeAdminAlpha(Uint8List.fromList(original),
        invalidation: invalidation, isCurrent: isCurrent);

/// Conservative opt-in path for a photo: unknown metadata, unsupported colour
/// formats, multiple scans and trailing data are never passed to the encoder.
Future<bool> isEligibleAdminPhotoJpeg(Uint8List bytes,
    {bool Function()? isCurrent}) async {
  if (bytes.length < 64 || bytes.length > 20 * 1024 * 1024 ||
      bytes[0] != 0xff || bytes[1] != 0xd8) return false;
  var p = 2, width = 0, height = 0, scans = 0;
  var sawJfif = false, sawExif = false;
  while (p + 2 <= bytes.length) {
    if (bytes[p++] != 0xff) return false;
    while (p < bytes.length && bytes[p] == 0xff) { p++; }
    if (p >= bytes.length) return false;
    final marker = bytes[p++];
    if (marker == 0xd9) return p == bytes.length && scans == 1 && sawJfif;
    if (p + 2 > bytes.length) return false;
    final length = (bytes[p] << 8) | bytes[p + 1];
    if (length < 2 || p + length > bytes.length) return false;
    if (marker == 0xe0) {
      if (sawJfif || length != 16 || bytes[p + 14] != 0 || bytes[p + 15] != 0 ||
          String.fromCharCodes(bytes.sublist(p + 2, p + 7)) != 'JFIF\x00') return false;
      sawJfif = true;
    } else if (marker == 0xe1) {
      if (sawExif || !_jpegExifUpright(bytes, p + 2, length - 2) ||
          !_photoExifSafe(bytes, p + 2, length - 2)) return false;
      sawExif = true;
    } else if (!const {0xc0, 0xc4, 0xdb, 0xdd, 0xda}.contains(marker)) {
      return false;
    }
    if (marker == 0xc0) {
      if (width != 0 || length != 17 || bytes[p + 2] != 8 || bytes[p + 7] != 3) return false;
      height = (bytes[p + 3] << 8) | bytes[p + 4];
      width = (bytes[p + 5] << 8) | bytes[p + 6];
      if (width == 0 || height == 0 || width * height > 20000000) return false;
    }
    p += length;
    if (marker == 0xda) {
      if (++scans != 1 || width == 0) return false;
      var nextYield = p + 65536;
      while (p + 1 < bytes.length) {
        if (p >= nextYield) {
          await Future<void>.delayed(Duration.zero);
          if (!(isCurrent?.call() ?? true)) return false;
          nextYield = p + 65536;
        }
        if (bytes[p++] != 0xff) continue;
        final next = bytes[p];
        if (next == 0 || (next >= 0xd0 && next <= 0xd7)) { p++; continue; }
        p--;
        break;
      }
    }
  }
  return false;
}

bool _photoExifSafe(Uint8List bytes, int start, int length) {
  try {
    final tiff = start + 6, end = start + length;
    final view = ByteData.sublistView(bytes);
    final order = String.fromCharCodes(bytes.sublist(tiff, tiff + 2));
    if (order != 'II' && order != 'MM') return false;
    final endian = order == 'II' ? Endian.little : Endian.big;
    // Only standard EXIF IFDs and known tags are allowed. Unknown tags can
    // represent private offsets or embedded containers, so they fail closed.
    const imageTags = <int>{
      0x0100,0x0101,0x0102,0x0103,0x0106,0x010e,0x010f,0x0110,
      0x0111,0x0112,0x0115,0x0116,0x0117,0x011a,0x011b,0x011c,
      0x0128,0x012d,0x0131,0x0132,0x013b,0x013c,0x013e,0x013f,
      0x0140,0x0156,0x0201,0x0202,0x0211,0x0212,0x0213,0x0214,
      0x8298,0x8769,0x8825,
    };
    const exifTags = <int>{
      0x829a,0x829d,0x8822,0x8824,0x8827,0x8830,0x8831,0x8832,0x8833,
      0x9000,0x9003,0x9004,0x9010,0x9011,0x9012,0x9101,0x9102,
      0x9201,0x9202,0x9203,0x9204,0x9205,0x9206,0x9207,0x9208,0x9209,0x920a,
      0x9214,0x9286,0x9290,0x9291,0x9292,0xa000,0xa001,0xa002,0xa003,0xa004,
      0xa005,0xa20b,0xa20c,0xa20e,0xa20f,0xa210,0xa214,0xa215,0xa217,
      0xa300,0xa301,0xa302,0xa401,0xa402,0xa403,0xa404,0xa405,0xa406,
      0xa407,0xa408,0xa409,0xa40a,0xa40b,0xa40c,0xa420,0xa430,0xa431,
      0xa432,0xa433,0xa434,0xa435,
    };
    const interopTags = <int>{0x0001,0x0002,0x1000,0x1001,0x1002};
    final queue = <(int, String)>[(view.getUint32(tiff + 4, endian), 'image')];
    final seen = <int>{};
    const sizes = <int, int>{1:1, 2:1, 3:2, 4:4, 5:8, 6:1, 7:1, 8:2, 9:4, 10:8, 11:4, 12:8};
    var total = 0;
    var sawOrientation = false;
    while (queue.isNotEmpty) {
      final (offset, kind) = queue.removeLast();
      final ifd = tiff + offset;
      if (offset < 8 || ifd + 2 > end || !seen.add(offset) || seen.length > 16) return false;
      final count = view.getUint16(ifd, endian);
      total += count;
      final last = ifd + 2 + count * 12;
      if (total > 512 || last + 4 > end) return false;
      for (var i = 0; i < count; i++) {
        final entry = ifd + 2 + i * 12;
        final tag = view.getUint16(entry, endian), type = view.getUint16(entry + 2, endian);
        final number = view.getUint32(entry + 4, endian), size = sizes[type];
        if (!(kind == 'image' ? imageTags.contains(tag)
            : kind == 'exif' ? exifTags.contains(tag)
            : kind == 'gps' ? tag <= 0x001f
            : interopTags.contains(tag))) return false;
        if (size == null || tag == 0x927c || number > length || number * size > length) return false;
        if (tag == 0x0112) {
          if (sawOrientation || type != 3 || number != 1 ||
              view.getUint16(entry + 8, endian) != 1) return false;
          sawOrientation = true;
        }
        if (number * size > 4) {
          final dataOffset = view.getUint32(entry + 8, endian);
          if (dataOffset > end - tiff - number * size) return false;
        }
        if (tag == 0x8769 || tag == 0x8825 || tag == 0xa005) {
          if (type != 4 || number != 1) return false;
          final next = view.getUint32(entry + 8, endian);
          if (next == 0) return false;
          queue.add((next, tag == 0x8769 ? 'exif' : tag == 0x8825 ? 'gps' : 'interop'));
        }
      }
      final next = view.getUint32(last, endian);
      if (next != 0) queue.add((next, kind));
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> isValidLegacyJpeg(Uint8List original, Uint8List encoded) =>
    compute(_validLegacyJpeg, [
      Uint8List.fromList(original),
      Uint8List.fromList(encoded),
    ]);

bool _validLegacyJpeg(List<Uint8List> inputs) {
  try {
    final original = inputs[0], encoded = inputs[1];
    final source = _jpegDimensions(original);
    if (source == null || source.$1 * source.$2 > 20000000) return false;
    final longest = source.$1 > source.$2 ? source.$1 : source.$2;
    final scale = longest > 1600 ? 1600 / longest : 1.0;
    final width = (source.$1 * scale).round().clamp(1, 1600);
    final height = (source.$2 * scale).round().clamp(1, 1600);
    if (encoded.length < 4 ||
        encoded.length > 5 * 1024 * 1024 ||
        encoded[0] != 0xff ||
        encoded[1] != 0xd8 ||
        encoded[2] != 0xff ||
        encoded[encoded.length - 2] != 0xff ||
        encoded.last != 0xd9)
      return false;
    final decoder = image.JpegDecoder();
    final info = decoder.startDecode(encoded);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width != width ||
        info.height != height)
      return false;
    final decoded = decoder.decodeFrame(0);
    return decoded != null &&
        decoded.width == info.width &&
        decoded.height == info.height;
  } catch (_) {
    return false;
  }
}

// Mirror the existing worker's conservative JPEG/EXIF allowlist before any
// transformation; metadata not understood by the legacy worker fails closed.
(int, int)? _jpegDimensions(Uint8List b) {
  if (b.length < 4 || b[0] != 0xff || b[1] != 0xd8) return null;
  final data = ByteData.sublistView(b);
  var offset = 2;
  (int, int)? dimensions;
  while (offset + 3 < b.length) {
    if (b[offset++] != 0xff) return null;
    while (offset < b.length && b[offset] == 0xff) {
      offset++;
    }
    if (offset >= b.length) return null;
    final marker = b[offset++];
    if (marker == 0xd9) break;
    if (marker == 0xda) return dimensions;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > b.length) return null;
    final length = data.getUint16(offset);
    if (length < 2 || offset + length > b.length) return null;
    if (marker == 0xe1 && !_jpegExifUpright(b, offset + 2, length - 2))
      return null;
    if (marker == 0xe2 || marker == 0xee) return null;
    if (const [0xc0, 0xc1, 0xc2].contains(marker)) {
      if (length < 8 || (b[offset + 7] != 1 && b[offset + 7] != 3)) return null;
      final height = data.getUint16(offset + 3),
          width = data.getUint16(offset + 5);
      if (width == 0 || height == 0) return null;
      dimensions = (width, height);
    }
    offset += length;
  }
  return null;
}

bool _jpegExifUpright(Uint8List b, int start, int length) {
  if (length < 14 ||
      String.fromCharCodes(b.sublist(start, start + 6)) != 'Exif\x00\x00')
    return false;
  final tiff = start + 6, end = start + length;
  final order = String.fromCharCodes(b.sublist(tiff, tiff + 2));
  if (order != 'II' && order != 'MM') return false;
  final endian = order == 'II' ? Endian.little : Endian.big;
  final view = ByteData.sublistView(b);
  if (tiff + 8 > end || view.getUint16(tiff + 2, endian) != 42) return false;
  final ifd = tiff + view.getUint32(tiff + 4, endian);
  if (ifd < tiff || ifd + 2 > end) return false;
  final count = view.getUint16(ifd, endian);
  if (count > 1024 || ifd + 2 + count * 12 > end) return false;
  for (var i = 0; i < count; i++) {
    final entry = ifd + 2 + i * 12;
    if (view.getUint16(entry, endian) != 274) continue;
    return view.getUint16(entry + 2, endian) == 3 &&
        view.getUint32(entry + 4, endian) == 1 &&
        view.getUint16(entry + 8, endian) == 1;
  }
  return true;
}

/// Untrusted/injected encoder results are verified again before upload.
Future<bool> isLosslessAdminPhoto(Uint8List original, Uint8List candidate) =>
    compute(_samePixels, [
      Uint8List.fromList(original),
      Uint8List.fromList(candidate),
    ]);

// Flutter's web compute runs on the main isolate. Keep its workload smaller;
// larger images remain untouched rather than freezing the editor indefinitely.
const _maxPngBytes = kIsWeb ? 2 * 1024 * 1024 : 5 * 1024 * 1024;
const _maxPixels = kIsWeb ? 1024 * 1024 : 4 * 1024 * 1024;
final _crcTable = List<int>.generate(256, (value) {
  var crc = value;
  for (var i = 0; i < 8; i++)
    crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
  return crc;
}, growable: false);

bool _validPng(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 57 || bytes.length > _maxPngBytes) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  final view = ByteData.sublistView(bytes);
  var offset = 8, chunk = 0;
  var hasData = false;
  while (offset + 12 <= bytes.length) {
    final length = view.getUint32(offset);
    if (length > bytes.length - offset - 12) return false;
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    // Reject all ancillary metadata, palette, APNG and unknown chunks.
    if (type != 'IHDR' && type != 'IDAT' && type != 'IEND') return false;
    if (chunk == 0) {
      if (type != 'IHDR' || length != 13) return false;
      final width = view.getUint32(offset + 8),
          height = view.getUint32(offset + 12);
      if (width == 0 ||
          height == 0 ||
          width * height > _maxPixels ||
          bytes[offset + 16] != 8 ||
          !const [0, 2, 4, 6].contains(bytes[offset + 17]) ||
          bytes[offset + 18] != 0 ||
          bytes[offset + 19] != 0 ||
          bytes[offset + 20] != 0)
        return false;
    } else if (type == 'IHDR') {
      return false;
    }
    var crc = 0xffffffff;
    for (var i = offset + 4; i < offset + 8 + length; i++) {
      crc = _crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    }
    if (((crc ^ 0xffffffff) & 0xffffffff) !=
        view.getUint32(offset + 8 + length))
      return false;
    if (type == 'IDAT') hasData = true;
    offset += length + 12;
    chunk++;
    if (type == 'IEND') return length == 0 && hasData && offset == bytes.length;
  }
  return false;
}

Uint8List? _optimise(Uint8List bytes) {
  try {
    if (!_validPng(bytes)) return null;
    final source = image.decodePng(bytes);
    if (source == null || source.numFrames != 1) return null;
    final result = image.encodePng(source, level: 9);
    if (result.length >= bytes.length || !_samePixels([bytes, result]))
      return null;
    return result;
  } catch (_) {
    return null;
  }
}

bool _samePixels(List<Uint8List> inputs) {
  try {
    final original = inputs[0], candidate = inputs[1];
    if (!_validPng(original) || !_validPng(candidate)) return false;
    final a = image.decodePng(original), b = image.decodePng(candidate);
    if (a == null ||
        b == null ||
        a.numFrames != 1 ||
        b.numFrames != 1 ||
        a.width != b.width ||
        a.height != b.height)
      return false;
    for (var y = 0; y < a.height; y++) {
      for (var x = 0; x < a.width; x++) {
        final p = a.getPixel(x, y), q = b.getPixel(x, y);
        if (p.r != q.r || p.g != q.g || p.b != q.b || p.a != q.a) return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}
