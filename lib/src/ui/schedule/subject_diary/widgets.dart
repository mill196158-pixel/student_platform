part of subject_diary;

/// =========================
/// МАЛЕНЬКИЕ/ЕДИНООБРАЗНЫЕ КНОПКИ
/// =========================

enum _ActionKind { normal, danger }

class _SmallActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final _ActionKind kind;
  const _SmallActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.kind = _ActionKind.normal,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDanger = kind == _ActionKind.danger;
    final fg = isDanger ? Colors.red.shade700 : Colors.black87;
    final side = BorderSide(color: fg.withOpacity(.28), width: 1);

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 32),
          side: side,
          foregroundColor: fg,
          textStyle: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: .1,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: Icon(icon, size: 16),
        label: Text(label),
      ),
    );
  }
}

class _InlineActions extends StatelessWidget {
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _InlineActions({required this.onEdit, required this.onDelete});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _SmallActionButton(icon: Icons.edit_rounded, label: 'Изменить', onTap: onEdit),
        const SizedBox(width: 8),
        _SmallActionButton(
          icon: Icons.delete_outline_rounded,
          label: 'Удалить',
          kind: _ActionKind.danger,
          onTap: onDelete,
        ),
      ],
    );
  }
}

/// =========================
/// ОБЩИЕ ВИДЖЕТЫ / УТИЛИТЫ
/// =========================

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.black,
            ),
      );
}

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  const _MiniIconButton({required this.icon, required this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withOpacity(.9),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, size: 16, color: Colors.black87),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Панель «добавить запись / фото / файлы»
class _AddBranchPanel extends StatelessWidget {
  final Future<void> Function() onPickGallery;
  final Future<void> Function() onPickCamera;
  final Future<void> Function() onAddFiles;
  final VoidCallback onNewText;
  final bool tinted;
  final bool disableNewText;
  const _AddBranchPanel({
    required this.onPickGallery,
    required this.onPickCamera,
    required this.onAddFiles,
    required this.onNewText,
    this.tinted = false,
    this.disableNewText = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BranchCard(
          icon: Icons.sticky_note_2_outlined,
          title: 'Заметка по предмету',
          subtitle: disableNewText ? 'Редактируйте текущую заметку' : 'Текстовая запись за выбранный день',
          tinted: tinted,
          disabled: disableNewText,
          onTap: disableNewText ? () {} : onNewText,
        ),
        _BranchCard(
          icon: Icons.photo_library_outlined,
          title: 'Фото-конспект',
          subtitle: 'Выбрать фото и сохранить набор',
          tinted: tinted,
          onTap: () { onPickGallery(); },
        ),
        _BranchCard(
          icon: Icons.attach_file,
          title: 'Файлы',
          subtitle: 'Документы и другие вложения',
          tinted: tinted,
          onTap: () { onAddFiles(); },
        ),
      ],
    );
  }
}

class _BranchCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool tinted;
  final bool disabled;
  const _BranchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tinted = false,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final basePrimary = theme.colorScheme.primary;
    final bg = disabled
        ? theme.colorScheme.surface.withOpacity(.6)
        : (tinted ? basePrimary.withOpacity(.08) : theme.colorScheme.surface);
    final iconBg = disabled ? theme.colorScheme.surface.withOpacity(.5) : basePrimary.withOpacity(.12);
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          boxShadow: !tinted
              ? [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: Icon(icon, color: disabled ? Colors.black38 : theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: disabled ? Colors.black45 : Colors.black,
                  )),
                  const SizedBox(height: 4),
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: disabled ? Colors.black26 : Colors.black.withOpacity(.64))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: disabled ? Colors.black26 : Colors.black54),
          ],
        ),
      ),
    );
  }
}

BoxDecoration _cardDeco(BuildContext context, {double radius = 16, double blur = 12}) {
  return BoxDecoration(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: [
      BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: blur, offset: const Offset(0, 3)),
    ],
  );
}

/// =========================
/// ШАПКА (с компактным заголовком для просмотра)
/// =========================

class _ModelHeader extends StatelessWidget {
  final String title;
  final String? subtitle;   // строка 1 (например, дата)
  final String? subtitle2;  // строка 2 (например, счётчики)
  final Widget? trailing;
  final bool compactTitle;  // ← делает заголовок меньше/в 1 строку
  const _ModelHeader({
    required this.title,
    this.subtitle,
    this.subtitle2,
    this.trailing,
    this.compactTitle = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Colors.white, theme.colorScheme.primary.withOpacity(0.06), theme.colorScheme.primary.withOpacity(0.12)],
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(children: [
            Positioned(left: -40, top: -20, child: _GlowCircle(diameter: 140, color: theme.colorScheme.primary.withOpacity(0.10))),
            Positioned(right: -30, bottom: -30, child: _GlowCircle(diameter: 160, color: Colors.white.withOpacity(0.55))),
          ]),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Align(
              alignment: const Alignment(-1, 0.25),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const _RoundBackButton(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Builder(builder: (context) {
                          final base = Theme.of(context).textTheme.headlineSmall?.fontSize ?? 24.0;
                          final titleSize = compactTitle ? (base / 2 - 2) : (base / 2 + 2);
                          return Text(
                            title,
                            maxLines: compactTitle ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontSize: titleSize.clamp(14, 20),
                                  fontWeight: FontWeight.w800,
                                  color: Colors.black,
                                  height: 1.05,
                                  shadows: compactTitle ? null : [Shadow(color: Colors.black.withOpacity(0.05), offset: const Offset(0, 2), blurRadius: 3)],
                                ),
                          );
                        }),
                        if (!compactTitle && subtitle != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Colors.black.withOpacity(0.64),
                                  height: 1.25,
                                ),
                          ),
                        ],
                        if (!compactTitle && subtitle2 != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle2!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.black.withOpacity(0.64),
                                  height: 1.25,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double diameter; final Color color;
  const _GlowCircle({required this.diameter, required this.color});
  @override
  Widget build(BuildContext context) => ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(width: diameter, height: diameter, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        ),
      );
}

/// Круглая кнопка «Назад»
class _RoundBackButton extends StatelessWidget {
  const _RoundBackButton();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: IconButton(
        tooltip: 'Назад',
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

/// =========================
/// КОНСПЕКТЫ (фото) — крестик только в editMode
/// =========================

class _PhotosGrid extends StatelessWidget {
  final List<_PickedImage> images;
  final void Function(int index) onRemove;
  final bool editMode; // ← добавлено
  final void Function(int index)? onOpen; // опционально: открыть просмотрщик
  const _PhotosGrid({
    required this.images,
    required this.onRemove,
    this.editMode = false,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: images.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1,
      ),
      itemBuilder: (ctx, i) {
        final img = images[i];
        return Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: () => onOpen?.call(i),
                  child: Image.memory(img.bytes, fit: BoxFit.cover),
                ),
              ),
            ),
            if (editMode)
              Positioned(
                right: 4, top: 4,
                child: InkWell(
                  onTap: () => onRemove(i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withOpacity(.92),
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(.1), blurRadius: 6)],
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(Icons.close_rounded, size: 16),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// =========================
/// ФАЙЛЫ — современная строка со скачиванием
/// =========================

class _FileRow extends StatefulWidget {
  final String name;
  final int size;
  final String mime;
  final Future<void> Function()? onDownload; // ← скачать (вместо ссылки)
  final VoidCallback? onDelete;
  const _FileRow({
    required this.name,
    required this.size,
    required this.mime,
    this.onDownload,
    this.onDelete,
  });

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _loading = false;

  IconData _iconByMime(String m) {
    final n = m.toLowerCase();
    if (n.startsWith('image/')) return Icons.image_outlined;
    if (n.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (n.contains('zip') || n.contains('rar') || n.contains('7z')) return Icons.archive_outlined;
    if (n.contains('sheet') || n.contains('excel') || n.contains('xls')) return Icons.grid_on_outlined;
    if (n.contains('word') || n.contains('doc')) return Icons.description_outlined;
    if (n.contains('presentation') || n.contains('ppt')) return Icons.slideshow_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _fmtSizeLocal(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} КБ';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} МБ';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ic = _iconByMime(widget.mime);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: widget.onDownload == null
          ? null
          : () async {
              setState(() => _loading = true);
              try { await widget.onDownload!.call(); }
              finally { if (mounted) setState(() => _loading = false); }
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))],
        ),
        child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(.10),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(ic, color: theme.colorScheme.primary, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: Colors.black)),
                const SizedBox(height: 2),
                Text(_fmtSizeLocal(widget.size),
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_loading)
            const SizedBox(
              width: 24, height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            Tooltip(
              message: 'Скачать',
              child: IconButton(
                icon: const Icon(Icons.download_rounded, size: 22),
                onPressed: widget.onDownload == null ? null : () async {
                  setState(() => _loading = true);
                  try { await widget.onDownload!.call(); }
                  finally { if (mounted) setState(() => _loading = false); }
                },
              ),
            ),
            Tooltip(
              message: 'Удалить',
              child: IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 22),
                color: Colors.red.shade700,
                onPressed: widget.onDelete,
              ),
            ),
          ],
        ],
        ),
      ),
    );
  }
}

/// =========================
/// ПУСТОЕ СОСТОЯНИЕ (анимация котика)
/// =========================

class _CatEmptyState extends StatelessWidget {
  const _CatEmptyState();

  static const _primary = 'assets/lottie/Cat_in_Box.json';
  static const _alt     = 'assets/lottie/00e30e9d-fad6-4b8d-a245-f03544ced00f.json';
  static const _sleep   = 'assets/lottie/cat_sleeping.json';

  Future<String> _pickPath() async {
    try { await rootBundle.loadString(_primary); return _primary; } catch (_) {}
    try { await rootBundle.loadString(_alt); return _alt; } catch (_) {}
    return _sleep;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<String>(
      future: _pickPath(),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 208);
        }
        final path = snap.data ?? _sleep;

        if (path == _sleep) {
          return _wrap(theme, Lottie.asset(_sleep, repeat: true, width: 200, height: 200));
        }

        return FutureBuilder<String>(
          future: rootBundle.loadString(path),
          builder: (ctx, s2) {
            if (s2.connectionState != ConnectionState.done) {
              return const SizedBox(height: 208);
            }
            try {
              final map = convert.jsonDecode(s2.data!) as Map<String, dynamic>;
              final ip = map['ip'], op = map['op'];
              if (ip != null && op != null && op == ip) {
                map['op'] = (op as num) + 1; // фикс «0 кадров»
                final bytes = Uint8List.fromList(convert.utf8.encode(convert.jsonEncode(map)));
                return _wrap(theme, Lottie.memory(bytes, repeat: true, width: 200, height: 200));
              }
              return _wrap(theme, Lottie.asset(path, repeat: true, width: 200, height: 200));
            } catch (_) {
              return _wrap(theme, Lottie.asset(_sleep, repeat: true, width: 200, height: 200));
            }
          },
        );
      },
    );
  }

  Widget _wrap(ThemeData theme, Widget child) => Column(
    children: [
      child,
      const SizedBox(height: 8),
      Text('У тебя тут ещё нет записей',
        style: theme.textTheme.bodyMedium?.copyWith(color: Colors.black54)),
    ],
  );
}

/// =========================
/// ГЛОБАЛЬНЫЕ УТИЛИТЫ (совместимость)
/// =========================

String _detectMime(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.gif')) return 'image/gif';
  if (n.endsWith('.webp')) return 'image/webp';
  if (n.endsWith('.pdf')) return 'application/pdf';
  if (n.endsWith('.doc')) return 'application/msword';
  if (n.endsWith('.docx')) return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  if (n.endsWith('.xls')) return 'application/vnd.ms-excel';
  if (n.endsWith('.xlsx')) return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  if (n.endsWith('.ppt')) return 'application/vnd.ms-powerpoint';
  if (n.endsWith('.pptx')) return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  if (n.endsWith('.txt')) return 'text/plain';
  if (n.endsWith('.csv')) return 'text/csv';
  if (n.endsWith('.zip')) return 'application/zip';
  return 'application/octet-stream';
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} КБ';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(1)} МБ';
}
