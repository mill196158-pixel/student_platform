import 'dart:io';
import 'package:flutter/services.dart' as services;
import 'package:flutter/widgets.dart';

const _channel = services.MethodChannel('keyboard_image_channel');

class KeyboardCaptureController {
  Future<void> focus() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('focus');
    }
  }

  Future<void> dispose() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('dispose');
    }
  }
}

typedef KeyboardPicked = void Function(String path);

class KeyboardCapture extends StatefulWidget {
  final KeyboardCaptureController controller;
  final KeyboardPicked onPicked;

  const KeyboardCapture({
    super.key,
    required this.controller,
    required this.onPicked,
  });

  @override
  State<KeyboardCapture> createState() => _KeyboardCaptureState();
}

class _KeyboardCaptureState extends State<KeyboardCapture> {
  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPicked') {
        final path = call.arguments as String;
        widget.onPicked(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
