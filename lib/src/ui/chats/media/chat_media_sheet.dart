import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:student_platform/src/services/chat_file_access.dart';
// FILE: lib/src/ui/chats/media/chat_media_sheet.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../common/friendly_empty_state.dart';

class ChatMediaSheet extends StatefulWidget {
  const ChatMediaSheet({super.key, required this.messagesStream});
  final Stream<List<Message>> messagesStream;

  @override
  State<ChatMediaSheet> createState() => _ChatMediaSheetState();
}

class _ChatMediaSheetState extends State<ChatMediaSheet>
    with TickerProviderStateMixin {
  late final TabController _tabs;
  StreamSubscription<List<Message>>? _sub;
  bool _loading = true;
  bool _failed = false;

  final _images = <ChatFile>[];
  final _docs = <ChatFile>[];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _sub = widget.messagesStream.listen(_rebuildMedia, onError: (Object _) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    });
  }

  void _rebuildMedia(List<Message> list) {
    final imgs = <ChatFile>[];
    final docs = <ChatFile>[];
    for (final m in list) {
      for (final f in (m.attachments ?? const <ChatFile>[])) {
        if (f.isImage)
          imgs.add(f);
        else
          docs.add(f);
      }
    }
    setState(() {
      _loading = false;
      _failed = false;
      _images
        ..clear()
        ..addAll(imgs.reversed);
      _docs
        ..clear()
        ..addAll(docs.reversed);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Медиа чата'),
            centerTitle: true,
            automaticallyImplyLeading: false,
            leading: IconButton(
                tooltip: 'Закрыть',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context)),
            bottom: TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: 'Фото'),
                Tab(text: 'Файлы'),
              ],
            ),
          ),
          body: Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
            child: _loading
                ? const Center(child: ProductLoadingIndicator.page())
                : _failed
                    ? const FriendlyEmptyState(
                        title: 'Не удалось загрузить медиа',
                        subtitle:
                            'Закройте окно и попробуйте открыть его снова',
                        fallbackIcon: Icons.cloud_off_outlined,
                        animationHeight: 72,
                      )
                    : TabBarView(
                        controller: _tabs,
                        children: [
                          _ImagesGrid(files: _images),
                          _DocsList(files: _docs),
                        ],
                      ),
          ),
        ),
      ),
    );
  }
}

class _ImagesGrid extends StatelessWidget {
  const _ImagesGrid({required this.files});
  final List<ChatFile> files;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return const FriendlyEmptyState(
        title: 'Пока нет фото',
        subtitle: 'Фотографии из этой переписки появятся здесь',
        fallbackIcon: Icons.photo_library_outlined,
        animationHeight: 72,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: files.length,
      itemBuilder: (ctx, i) {
        final f = files[i];
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () async {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FullscreenImage(
                    imageUrl: f.fileUrl,
                    fileName: f.fileName,
                    sourceFileId: f.id,
                    galleryUrls: files.map((e) => e.fileUrl).toList(),
                    galleryFileNames: files.map((e) => e.fileName).toList(),
                    galleryFileIds: files.map((e) => e.id).toList(),
                    initialIndex: i,
                  ),
                ),
              );
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                AuthorizedFileImage(
                  imageUrl: f.fileUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: const Center(child: ProductLoadingIndicator(size: 72)),
                  ),
                  errorWidget: (_, __, ___) => ColoredBox(
                    color: scheme.errorContainer.withValues(alpha: 0.42),
                    child: Icon(Icons.broken_image_outlined,
                        color: scheme.onSurfaceVariant),
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.54),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      FileUiUtils.formatFileSize(f.fileSize),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DocsList extends StatelessWidget {
  const _DocsList({required this.files});
  final List<ChatFile> files;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return const FriendlyEmptyState(
        title: 'Пока нет файлов',
        subtitle: 'Документы из этой переписки появятся здесь',
        fallbackIcon: Icons.folder_outlined,
        animationHeight: 72,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final f = files[i];
        return AppFileCard(
          fileName: f.fileName,
          fileSize: f.fileSize,
          mimeType: f.fileType,
          onTap: () async {
            final url = f.fileUrl;
            if (url.isNotEmpty) {
              final uri = Uri.parse(await ChatFileAccess.resolve(url));
              if (await canLaunchUrl(uri))
                await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          trailing: Icon(
            Icons.open_in_new_rounded,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
