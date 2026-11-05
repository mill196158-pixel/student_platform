import 'package:flutter/material.dart';

/// The platform's owl and academic cap. The mark also renders at launcher size.
class ProductOwlMark extends StatelessWidget {
  const ProductOwlMark({super.key, required this.color, this.blink = 0});

  final Color color;
  final double blink;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _OwlPainter(color, blink),
        child: const SizedBox.expand(),
      );
}

class _OwlPainter extends CustomPainter {
  const _OwlPainter(this.color, this.blink);

  final Color color;
  final double blink;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 100;
    canvas.save();
    canvas.translate(
        (size.width - 100 * scale) / 2, (size.height - 100 * scale) / 2);
    canvas.scale(scale);
    final fill = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final cap = Path()
      ..moveTo(7, 31)
      ..lineTo(50, 14)
      ..lineTo(93, 31)
      ..lineTo(50, 48)
      ..close();
    canvas.drawPath(cap, fill);
    canvas.drawLine(const Offset(86, 33), const Offset(86, 48), line);
    canvas.drawCircle(const Offset(86, 49), 3.3, fill);

    final eyeHeight = 28 - 22 * blink.clamp(0.0, 1.0);
    for (final x in [33.0, 67.0]) {
      final center = Offset(x, 63);
      canvas.drawOval(
          Rect.fromCenter(center: center, width: 28, height: eyeHeight), line);
      canvas.drawOval(
          Rect.fromCenter(center: center, width: 10, height: eyeHeight / 2.8),
          fill);
    }
    canvas.drawPath(
        Path()
          ..moveTo(50, 74)
          ..lineTo(56, 81)
          ..lineTo(50, 88)
          ..lineTo(44, 81)
          ..close(),
        fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OwlPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.blink != blink;
}
