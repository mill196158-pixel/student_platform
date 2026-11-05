import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import '../shared/workspace_page_header.dart';
import '../common/friendly_empty_state.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/src/ui/schedule/subject_diary/subject_diary.dart'
    show SubjectDiaryEntry, SubjectDiaryFile, SubjectDiaryRepository;

/// Детальная страница записи: «Конспекты», «Заметка», «Файлы»
class DiaryEntryDetailsScreen extends StatelessWidget {
  final SubjectDiaryEntry entry;
  const DiaryEntryDetailsScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = SubjectDiaryRepository.instance;

    final images =
        entry.files.where((f) => f.mime.startsWith('image/')).toList();
    final otherFiles =
        entry.files.where((f) => !f.mime.startsWith('image/')).toList();

    return Scaffold(
      body: Column(
        children: [
          WorkspacePageHeader(title: 'Запись от ${_fmtDate(entry.date)}'),
          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(
                  vertical: 24,
                  horizontal: ((MediaQuery.sizeOf(context).width - 800) / 2)
                      .clamp(16.0, double.infinity)),
              children: [
                // Конспекты-фото
                if (images.isNotEmpty) ...[
                  _SectionTitle('Конспекты'),
                  const SizedBox(height: 8),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: images.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemBuilder: (ctx, i) {
                      final f = images[i];
                      final bytes = repo.getLocalThumb(f.url);
                      return InkWell(
                        onTap: bytes == null
                            ? null
                            : () => _openImageViewer(ctx, images, i),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: bytes != null
                              ? Image.memory(bytes, fit: BoxFit.cover)
                              : const ColoredBox(color: Color(0x11000000)),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                ],

                // Заметка-текст
                if ((entry.text ?? '').trim().isNotEmpty) ...[
                  _SectionTitle('Заметка'),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: _cardDeco(context),
                    child: Text(entry.text!.trim(),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.onSurface)),
                  ),
                  const SizedBox(height: 16),
                ],

                // Файлы
                if (otherFiles.isNotEmpty ||
                    (images.isNotEmpty && otherFiles.isEmpty)) ...[
                  _SectionTitle('Файлы'),
                  const SizedBox(height: 8),
                  ...entry.files.map((f) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Icon(f.mime.startsWith('image/')
                                ? Icons.image_outlined
                                : Icons.insert_drive_file_outlined),
                            const SizedBox(width: 10),
                            Expanded(child: Text(f.name, softWrap: true)),
                            const SizedBox(width: 8),
                            Text(_fmtSize(f.size),
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} КБ';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} МБ';
  }
}

Future<void> _openImageViewer(
    BuildContext ctx, List<SubjectDiaryFile> imgs, int start) async {
  final controller = PageController(initialPage: start);
  int cur = start;

  await showDialog(
    context: ctx,
    barrierColor: Colors.black.withOpacity(.95),
    builder: (_) => StatefulBuilder(
      builder: (dCtx, setS) {
        return Stack(
          children: [
            PageView.builder(
              controller: controller,
              itemCount: imgs.length,
              onPageChanged: (i) => setS(() => cur = i),
              itemBuilder: (c, i) {
                final repo = SubjectDiaryRepository.instance;
                final b = repo.getFileBytes(imgs[i].url) ??
                    repo.getLocalThumb(imgs[i].url);
                return Center(
                  child: InteractiveViewer(
                    child: b != null
                        ? Image.memory(b, fit: BoxFit.contain)
                        : const SizedBox(),
                  ),
                );
              },
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: true,
                child: Container(
                  height: 96,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xAA000000),
                        Color(0x33000000),
                        Colors.transparent
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    _viewerIconButton(
                        icon: Icons.close, onTap: () => Navigator.pop(dCtx)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(.35),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          imgs[cur].name,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _viewerIconButton(
                        icon: Icons.download,
                        onTap: () async {
                          final repo = SubjectDiaryRepository.instance;
                          final b = repo.getFileBytes(imgs[cur].url) ??
                              repo.getLocalThumb(imgs[cur].url);
                          if (b == null) return;
                          try {
                            final dir = await getTemporaryDirectory();
                            final path = '${dir.path}/${imgs[cur].name}';
                            final file = File(path);
                            await file.writeAsBytes(b, flush: true);
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text('Сохранено во временную папку')),
                              );
                            }
                          } catch (_) {}
                        }),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

Widget _viewerIconButton(
    {required IconData icon, required VoidCallback onTap}) {
  return Material(
    color: Colors.black.withOpacity(.35),
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    ),
  );
}

class AllConspectsGalleryScreen extends StatelessWidget {
  final String subjectKey;
  final Future<List<SubjectDiaryEntry>> entriesFuture;
  const AllConspectsGalleryScreen(
      {super.key, required this.subjectKey, required this.entriesFuture});

  @override
  Widget build(BuildContext context) {
    final repo = SubjectDiaryRepository.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Все конспекты')),
      body: FutureBuilder<List<SubjectDiaryEntry>>(
        future: entriesFuture,
        builder: (ctx, snap) {
          if (!snap.hasData)
            return const Center(child: ProductLoadingIndicator.page());
          final images = <SubjectDiaryFile>[];
          for (final e in snap.data!) {
            images.addAll(e.files.where((f) => f.mime.startsWith('image/')));
          }
          if (images.isEmpty) {
            return const FriendlyEmptyState(
              title: 'Нет фотографий конспектов',
              fallbackIcon: Icons.photo_library_outlined,
              animationHeight: 56,
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemCount: images.length,
            itemBuilder: (ctx, i) {
              final f = images[i];
              final bytes = repo.getLocalThumb(f.url);
              return InkWell(
                onTap: bytes == null
                    ? null
                    : () {
                        showDialog(
                            context: ctx,
                            builder: (_) {
                              return Dialog(
                                backgroundColor: Colors.black,
                                insetPadding: const EdgeInsets.all(12),
                                child: InteractiveViewer(
                                  child: bytes != null
                                      ? Image.memory(bytes, fit: BoxFit.contain)
                                      : const SizedBox(),
                                ),
                              );
                            });
                      },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: bytes != null
                      ? Image.memory(bytes, fit: BoxFit.cover)
                      : const ColoredBox(color: Color(0x11000000)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class AllFilesScreen extends StatelessWidget {
  final String subjectKey;
  final Future<List<SubjectDiaryEntry>> entriesFuture;
  const AllFilesScreen(
      {super.key, required this.subjectKey, required this.entriesFuture});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Все файлы')),
      body: FutureBuilder<List<SubjectDiaryEntry>>(
        future: entriesFuture,
        builder: (ctx, snap) {
          if (!snap.hasData)
            return const Center(child: ProductLoadingIndicator.page());
          final files = <SubjectDiaryFile>[];
          for (final e in snap.data!) {
            files.addAll(e.files);
          }
          if (files.isEmpty) {
            return const FriendlyEmptyState(
              title: 'Файлы не найдены',
              fallbackIcon: Icons.folder_open_outlined,
              animationHeight: 56,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            itemCount: files.length,
            separatorBuilder: (_, __) => const Divider(height: 12),
            itemBuilder: (ctx, i) {
              final f = files[i];
              return Row(
                children: [
                  Icon(f.mime.startsWith('image/')
                      ? Icons.image_outlined
                      : Icons.insert_drive_file_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(f.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  Text(_fmtSize(f.size),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              );
            },
          );
        },
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} КБ';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} МБ';
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.titleMedium);
}

BoxDecoration _cardDeco(BuildContext context, {double radius = 16}) {
  return BoxDecoration(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
  );
}
