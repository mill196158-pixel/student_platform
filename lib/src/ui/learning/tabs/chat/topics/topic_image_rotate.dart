import 'dart:typed_data';
import 'dart:ui' as ui;

/// Rotates image [bytes] clockwise by [degrees] (0/90/180/270).
Future<Uint8List> rotateTopicImageBytes({
  required Uint8List bytes,
  required int degrees,
}) async {
  final normalized = _normalizeDegrees(degrees);
  if (normalized == 0) return bytes;

  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final rotated = await _rotateUiImage(image, normalized);
      try {
        final data = await rotated.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw FormatException('Не удалось повернуть изображение.');
        }
        return data.buffer.asUint8List();
      } finally {
        rotated.dispose();
      }
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

int _normalizeDegrees(int degrees) {
  final mod = degrees % 360;
  if (mod == 0 || mod == 90 || mod == 180 || mod == 270) return mod;
  throw FormatException('Поворот возможен только на 0°, 90°, 180° или 270°.');
}

Future<ui.Image> _rotateUiImage(ui.Image image, int degrees) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final width = image.width.toDouble();
  final height = image.height.toDouble();

  switch (degrees) {
    case 90:
      canvas.translate(height, 0);
      canvas.rotate(1.5707963267948966);
      canvas.drawImage(image, ui.Offset.zero, ui.Paint());
      return recorder.endRecording().toImage(height.round(), width.round());
    case 180:
      canvas.translate(width, height);
      canvas.rotate(3.141592653589793);
      canvas.drawImage(image, ui.Offset.zero, ui.Paint());
      return recorder.endRecording().toImage(width.round(), height.round());
    case 270:
      canvas.translate(0, width);
      canvas.rotate(-1.5707963267948966);
      canvas.drawImage(image, ui.Offset.zero, ui.Paint());
      return recorder.endRecording().toImage(height.round(), width.round());
    default:
      return recorder.endRecording().toImage(width.round(), height.round());
  }
}
