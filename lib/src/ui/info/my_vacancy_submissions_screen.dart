import 'package:flutter/material.dart';

import 'propose_vacancy_screen.dart';
import 'vacancy_submission_service.dart';

/// Lists the caller's vacancy submissions (incl. drafts needing clarification).
class MyVacancySubmissionsScreen extends StatefulWidget {
  const MyVacancySubmissionsScreen({
    super.key,
    this.submissionService,
  });

  final VacancySubmissionService? submissionService;

  @override
  State<MyVacancySubmissionsScreen> createState() =>
      _MyVacancySubmissionsScreenState();
}

class _MyVacancySubmissionsScreenState
    extends State<MyVacancySubmissionsScreen> {
  late final VacancySubmissionService _service;
  List<MyVacancySubmissionItem> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _service = widget.submissionService ?? VacancySubmissionService();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _service.listMySubmissions();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String _statusLabel(String status) {
    return switch (status) {
      'draft' => 'Нужно уточнение / черновик',
      'submitted' => 'Отправлена',
      'in_moderation' => 'На модерации',
      'rejected' => 'Отклонена',
      'approved' => 'Одобрена',
      'published' => 'Опубликована',
      _ => status,
    };
  }

  Future<void> _openItem(MyVacancySubmissionItem item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProposeVacancyScreen(
          submissionService: _service,
          existingSubmission: item,
        ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Мои заявки на вакансии')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Черновики после запроса уточнения можно исправить и '
                    'отправить снова.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF6B7280),
                        ),
                  ),
                  const SizedBox(height: 16),
                  if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('Заявок пока нет')),
                    ),
                  for (final item in _items)
                    Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        title: Text(item.title),
                        subtitle: Text(
                          [
                            _statusLabel(item.status),
                            if (item.rejectionReason != null)
                              'Комментарий: ${item.rejectionReason}',
                          ].join('\n'),
                        ),
                        isThreeLine: item.rejectionReason != null,
                        trailing: item.status == 'draft'
                            ? const Icon(Icons.edit_outlined)
                            : const Icon(Icons.chevron_right),
                        onTap: item.status == 'draft'
                            ? () => _openItem(item)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
