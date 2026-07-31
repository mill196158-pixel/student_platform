import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'student_vacancy_card.dart';
import 'vacancy_models.dart';

/// Shared vacancy detail sheet (Mobile + can be reused in Admin preview flows).
class StudentVacancyDetailSheet extends StatefulWidget {
  const StudentVacancyDetailSheet({
    super.key,
    required this.card,
    this.showDemoBadge = false,
    this.logoBytes,
    this.coverBytes,
    this.backgroundBytes,
    this.showCloseButton = true,
    this.onOpenExternalUrl,
    this.onRevealContacts,
    this.onOpenAsset,
    this.onReport,
  });

  final ManagedVacancyCard card;
  final bool showDemoBadge;
  final Uint8List? logoBytes;
  final Uint8List? coverBytes;
  final Uint8List? backgroundBytes;

  /// When false, hides the trailing «Закрыть» button (embedded phone preview).
  final bool showCloseButton;

  final Future<void> Function(String httpsUrl)? onOpenExternalUrl;
  final Future<VacancyContacts?> Function()? onRevealContacts;
  final Future<void> Function(String assetId)? onOpenAsset;
  final Future<void> Function(VacancyReportReason reason, String? note)?
      onReport;

  @override
  State<StudentVacancyDetailSheet> createState() =>
      _StudentVacancyDetailSheetState();
}

class _StudentVacancyDetailSheetState extends State<StudentVacancyDetailSheet> {
  VacancyContacts? _contacts;
  bool _contactsLoading = false;
  bool _contactsError = false;
  bool _reportSent = false;

  ManagedVacancyCard get card => widget.card;
  VacancyCardPayload get payload => card.payload;

  Uint8List? get _logoBytes {
    if (widget.logoBytes != null && widget.logoBytes!.isNotEmpty) {
      return widget.logoBytes;
    }
    final raw = card.logoBytes;
    if (raw == null || raw.isEmpty) return null;
    return raw is Uint8List ? raw : Uint8List.fromList(raw);
  }

  Uint8List? get _coverBytes {
    if (widget.coverBytes != null && widget.coverBytes!.isNotEmpty) {
      return widget.coverBytes;
    }
    final raw = card.coverBytes;
    if (raw == null || raw.isEmpty) return null;
    return raw is Uint8List ? raw : Uint8List.fromList(raw);
  }

  Uint8List? get _backgroundBytes {
    if (widget.backgroundBytes != null && widget.backgroundBytes!.isNotEmpty) {
      return widget.backgroundBytes;
    }
    final raw = card.backgroundBytes;
    if (raw == null || raw.isEmpty) return null;
    return raw is Uint8List ? raw : Uint8List.fromList(raw);
  }

  Future<void> _revealContacts() async {
    if (_contacts != null || _contactsLoading) return;
    final fetch = widget.onRevealContacts;
    if (fetch == null) return;

    setState(() {
      _contactsLoading = true;
      _contactsError = false;
    });

    try {
      final value = await fetch();
      if (!mounted) return;
      setState(() {
        _contacts = value;
        _contactsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _contactsLoading = false;
        _contactsError = true;
      });
    }
  }

  Future<void> _report() async {
    final report = widget.onReport;
    if (report == null || _reportSent) return;

    final reason = await showDialog<VacancyReportReason>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Пожаловаться на вакансию'),
        children: [
          for (final r in VacancyReportReason.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, r),
              child: Text(r.labelRu),
            ),
        ],
      ),
    );

    if (reason == null) return;

    try {
      await report(reason, null);
      if (!mounted) return;
      setState(() => _reportSent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Жалоба отправлена.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = _backgroundBytes;

    final body = SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StudentVacancyCard(
              payload: payload,
              showDemoBadge: widget.showDemoBadge || card.showDemoBadge,
              expiresLabel: vacancyExpiresLabel(card.expiresAt),
              hasContacts: card.hasContacts,
              logoBytes: _logoBytes,
              coverBytes: _coverBytes,
            ),
            const SizedBox(height: 16),
            if (payload.descriptionFull != null &&
                payload.descriptionFull!.isNotEmpty &&
                payload.descriptionFull != payload.summary) ...[
              Text(
                'Описание',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(payload.descriptionFull!),
              const SizedBox(height: 14),
            ],
            if (payload.requirementsText != null &&
                payload.requirementsText!.isNotEmpty) ...[
              Text(
                'Требования',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(payload.requirementsText!),
              const SizedBox(height: 14),
            ],
            if (card.hasAssets) ...[
              Text(
                'Вложения',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final asset in card.assets)
                    OutlinedButton.icon(
                      onPressed: widget.onOpenAsset == null
                          ? null
                          : () => widget.onOpenAsset!(asset.id),
                      icon: Icon(
                        asset.kind == VacancyAssetKind.pdf
                            ? Icons.picture_as_pdf_outlined
                            : asset.kind == VacancyAssetKind.image
                                ? Icons.image_outlined
                                : Icons.attach_file_outlined,
                        size: 18,
                      ),
                      label: Text(asset.displayLabel),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (card.hasContacts) ...[
              Text(
                'Контакты',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              if (_contacts == null && !_contactsLoading)
                OutlinedButton(
                  onPressed:
                      widget.onRevealContacts == null ? null : _revealContacts,
                  child: const Text('Показать контакты'),
                )
              else if (_contactsLoading)
                const LinearProgressIndicator()
              else if (_contactsError)
                Text(
                  'Контакты недоступны.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else if (_contacts != null && !_contacts!.isEmpty) ...[
                if (_contacts!.person != null)
                  _contactRow('Контакт', _contacts!.person!),
                if (_contacts!.email != null)
                  _contactRow('Email', _contacts!.email!),
                if (_contacts!.phone != null)
                  _contactRow('Телефон', _contacts!.phone!),
                if (_contacts!.telegram != null)
                  _contactRow('Telegram', _contacts!.telegram!),
                if (_contacts!.url != null)
                  _contactRow('Ссылка', _contacts!.url!),
                if (_contacts!.note != null)
                  _contactRow('Примечание', _contacts!.note!),
              ],
              const SizedBox(height: 14),
            ],
            if (payload.hasExternalUrl) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: widget.onOpenExternalUrl == null
                      ? null
                      : () => widget.onOpenExternalUrl!(payload.externalUrl!),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Открыть на сайте'),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (widget.onReport != null && !widget.showDemoBadge)
                  TextButton.icon(
                    onPressed: _reportSent ? null : _report,
                    icon: const Icon(Icons.flag_outlined),
                    label: Text(
                      _reportSent ? 'Жалоба отправлена' : 'Пожаловаться',
                    ),
                  ),
                const Spacer(),
                if (widget.showCloseButton)
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Закрыть'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );

    if (background == null || background.isEmpty) return body;

    return Stack(
      children: [
        Positioned.fill(
          child: Image.memory(
            background,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        ),
        Positioned.fill(
          child: ColoredBox(
            color: const Color(0xFFFAF8FC).withValues(alpha: 0.78),
          ),
        ),
        body,
      ],
    );
  }

  Widget _contactRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodyMedium,
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}
