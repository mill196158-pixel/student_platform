import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'admin_image_store.dart';

class NewsItem {
  const NewsItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.variant,
    required this.colors,
    this.isHidden = false,
    this.imageId,
    this.imageFocus = Alignment.center,
    this.overlayDarken = 0.42,
  });

  final int id;
  final String title;
  final String subtitle;
  final StudentHomeNewsVariant variant;
  final List<Color> colors;
  final bool isHidden;

  /// Reference into [AdminImageStore]. Bytes are never persisted to disk/Git.
  final String? imageId;
  final Alignment imageFocus;
  final double overlayDarken;

  bool get usesImage =>
      variant == StudentHomeNewsVariant.imageOnly ||
      variant == StudentHomeNewsVariant.imageOverlay ||
      variant == StudentHomeNewsVariant.imageWithText;

  NewsItem copyWith({
    int? id,
    String? title,
    String? subtitle,
    StudentHomeNewsVariant? variant,
    List<Color>? colors,
    bool? isHidden,
    String? imageId,
    bool clearImageId = false,
    Alignment? imageFocus,
    double? overlayDarken,
  }) {
    return NewsItem(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      variant: variant ?? this.variant,
      colors: colors ?? this.colors,
      isHidden: isHidden ?? this.isHidden,
      imageId: clearImageId ? null : (imageId ?? this.imageId),
      imageFocus: imageFocus ?? this.imageFocus,
      overlayDarken: overlayDarken ?? this.overlayDarken,
    );
  }

  StudentHomeNews toPresentation(AdminImageStore imageStore) {
    const icons = [
      Icons.auto_awesome_rounded,
      Icons.edit_note_rounded,
      Icons.folder_copy_outlined,
      Icons.assignment_turned_in_outlined,
    ];
    final Uint8List? bytes = imageId == null
        ? null
        : imageStore.getBytes(imageId!);
    return StudentHomeNews(
      id: 'admin-news-$id',
      title: title,
      subtitle: subtitle,
      body: subtitle,
      icon: icons[id % icons.length],
      gradientColors: colors,
      variant: variant,
      imageBytes: bytes,
      imageFocus: imageFocus,
      overlayDarken: overlayDarken,
    );
  }
}

extension StudentHomeNewsVariantLabel on StudentHomeNewsVariant {
  String get label => switch (this) {
    StudentHomeNewsVariant.gradientText => 'gradientText',
    StudentHomeNewsVariant.imageOverlay => 'imageOverlay',
    StudentHomeNewsVariant.imageOnly => 'imageOnly',
    StudentHomeNewsVariant.imageWithText => 'imageWithText',
  };

  String get russianLabel => switch (this) {
    StudentHomeNewsVariant.gradientText => 'Градиент и текст',
    StudentHomeNewsVariant.imageOverlay => 'Картинка с текстом поверх',
    StudentHomeNewsVariant.imageOnly => 'Только картинка',
    StudentHomeNewsVariant.imageWithText => 'Картинка и текстовый блок',
  };
}
