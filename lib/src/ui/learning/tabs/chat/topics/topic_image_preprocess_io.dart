import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';

import 'topic_image_preprocess.dart';
import 'topic_image_rotate.dart';

TopicImagePreprocessor createTopicImagePreprocessorImpl() {
  return _IoTopicImagePreprocessor();
}

class _IoTopicImagePreprocessor extends TopicImagePreprocessor {
  @override
  Future<Uint8List?> crop({required Uint8List bytes}) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return null;
    }

    final tempPath = await _writeTemp(bytes);
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: tempPath,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Обрезка',
            toolbarWidgetColor: Colors.white,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
          IOSUiSettings(
            title: 'Обрезка',
          ),
        ],
      );
      if (cropped == null) return null;
      try {
        return await File(cropped.path).readAsBytes();
      } finally {
        try {
          await File(cropped.path).delete();
        } catch (_) {
          // Ignore temp cleanup failures.
        }
      }
    } finally {
      try {
        await File(tempPath).delete();
      } catch (_) {
        // Ignore temp cleanup failures.
      }
    }
  }

  @override
  Future<Uint8List> rotate({
    required Uint8List bytes,
    required int degrees,
  }) {
    return rotateTopicImageBytes(bytes: bytes, degrees: degrees);
  }

  Future<String> _writeTemp(Uint8List bytes) async {
    final file = File(
      '${Directory.systemTemp.path}/topic_crop_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
