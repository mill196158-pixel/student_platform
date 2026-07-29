import 'package:flutter/material.dart';

import 'subject_card_models.dart';

/// Shared phone-sized subject card preview (Mobile + Admin).
///
/// Renders sections in [SubjectCardPayload.sectionOrder]. Never shows empty
/// sections. No HTML/JS.
class StudentSubjectCardPreview extends StatelessWidget {
  const StudentSubjectCardPreview({
    super.key,
    required this.payload,
    this.width = 320,
    this.height = 640,
  });

  final SubjectCardPayload payload;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F5FF),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFD9D3F5)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
              color: const Color(0xFF5B4BDB),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    payload.canonicalName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (payload.controlForm != null)
                        _Chip(label: payload.controlForm!),
                      if (payload.department != null)
                        _Chip(label: payload.department!),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                children: [
                  ..._assetWidgets(context),
                  for (final key in payload.sectionOrder)
                    ..._sectionWidgets(context, key),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _assetWidgets(BuildContext context) {
    final assets = payload.displayAssets;
    final out = <Widget>[];
    final hero = assets.heroImage;
    if (hero != null) {
      out.add(
        _Section(
          title: 'Обложка',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 96,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E7FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFC7D2FE)),
                ),
                alignment: Alignment.center,
                child: Icon(
                  hero.isPdf ? Icons.picture_as_pdf : Icons.image_outlined,
                  size: 36,
                  color: const Color(0xFF4338CA),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                hero.title.isNotEmpty ? hero.title : hero.mimeType,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '${_formatBytes(hero.byteSize)} · v${hero.versionNumber}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (assets.attachments.isNotEmpty) {
      out.add(
        _Section(
          title: 'Файлы',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final file in assets.attachments)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        file.isPdf
                            ? Icons.picture_as_pdf_outlined
                            : Icons.attach_file,
                        size: 18,
                        color: const Color(0xFF4338CA),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file.title.isNotEmpty ? file.title : file.mimeType,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${file.mimeType} · ${_formatBytes(file.byteSize)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return out;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  List<Widget> _sectionWidgets(BuildContext context, String key) {
    final title = SubjectCardPayload.sectionTitleRu(key);
    switch (key) {
      case 'useful_links':
        if (payload.usefulLinks.isEmpty) return const [];
        return [
          _Section(
            title: title,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final link in payload.usefulLinks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      link.title,
                      style: const TextStyle(
                        color: Color(0xFF4338CA),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ];
      case 'teachers':
        if (payload.teachers.isEmpty) return const [];
        return [
          _Section(
            title: title,
            child: Text(
              payload.teachers.map((t) => t.displayName).join(', '),
            ),
          ),
        ];
      case 'hours_credits':
        if (!payload.hoursCreditsAvailable) {
          return [
            _Section(
              title: title,
              child: const Text('Недоступно без выбранного offering'),
            ),
          ];
        }
        return [
          _Section(
            title: title,
            child: Text(
              [
                if (payload.hoursTotal != null) 'Часы: ${payload.hoursTotal}',
                if (payload.credits != null) 'ЗЕ: ${payload.credits}',
              ].join(' · '),
            ),
          ),
        ];
      case 'relevance_date':
        if (payload.relevanceDate == null) return const [];
        final d = payload.relevanceDate!.toIso8601String().substring(0, 10);
        return [
          _Section(title: title, child: Text('Актуально на $d')),
        ];
      default:
        final text = payload.textForSection(key);
        if (text == null || text.isEmpty) return const [];
        return [_Section(title: title, child: Text(text))];
    }
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF312E81),
                ),
          ),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  color: const Color(0xFF1F2937),
                  height: 1.35,
                ),
            child: child,
          ),
        ],
      ),
    );
  }
}
