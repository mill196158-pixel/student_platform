import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _user;
  bool _loading = true;

  final _sb = Supabase.instance.client;
  RealtimeChannel? _channel; // для live-обновлений

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('user');
    if (userJson != null) {
      _user = jsonDecode(userJson) as Map<String, dynamic>;
      _subscribeStatus(); // слушаем изменения в БД
    }
    setState(() => _loading = false);
  }

  void _subscribeStatus() {
    if (_user == null) return;
    final id = _user!['id'] as String?;
    if (id == null) return;

    // На всякий случай отписка, если уже подписаны
    _channel?.unsubscribe();

    _channel = _sb
        .channel('public:users')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: id,
          ),
          callback: (payload) async {
            final newRec = payload.newRecord;
            if (newRec == null) return;

            final newStatus = (newRec['status'] ?? '') as String;
            final newAvatar = (newRec['avatar_url'] ?? '') as String;

            setState(() {
              if (_user != null) {
                _user!['status'] = newStatus;
                _user!['avatar_url'] = newAvatar;
              }
            });

            final prefs = await SharedPreferences.getInstance();
            final u = Map<String, dynamic>.from(_user!);
            u['status'] = newStatus;
            u['avatar_url'] = newAvatar;
            _user = u;
            await prefs.setString('user', jsonEncode(u));
          },
        )
        .subscribe();
  }

  Future<void> _refreshFromServer() async {
    if (_user == null) return;
    final id = _user!['id'] as String?;
    if (id == null) return;

    final fresh = await _sb
        .from('users')
        .select(
          'id, login, name, surname, university, group_name, avatar_url, status',
        )
        .eq('id', id)
        .maybeSingle();

    if (fresh != null) {
      final mapFresh = Map<String, dynamic>.from(fresh as Map);
      _user = mapFresh;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user', jsonEncode(mapFresh));
      setState(() {});
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('loggedIn');
    await prefs.remove('user');
    if (!mounted) return;
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Профиль'), centerTitle: true),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final u = _user;
    final first = (u?['name'] ?? '') as String;
    final last = (u?['surname'] ?? '') as String;
    final uni = (u?['university'] ?? '') as String;
    final group = (u?['group_name'] ?? '') as String;
    final status = (u?['status'] ?? '') as String;
    final avatar = (u?['avatar_url'] as String?)?.trim();

    final fullName = [first, last].where((s) => s.isNotEmpty).join(' ').trim();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
        centerTitle: true,
        leading: IconButton(
          tooltip: 'Редактировать',
          icon: const Icon(Icons.tune),
          onPressed: () async {
            await context.push('/edit-profile');
            // после возврата: подтянем локальный кэш (он уже обновлён в Edit)
            await _loadLocal();
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshFromServer,
          ),
          IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshFromServer,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _Header(
              fullName: fullName.isEmpty ? 'Без имени' : fullName,
              university: uni,
              groupName: group,
              status: status,
              avatarUrl: avatar,
            ),
            const SizedBox(height: 16),
            _MetricsRow(messages: '0', rating: '957', friends: '0'),
            const SizedBox(height: 20),

            const _SectionTitle('Лента'),
            const SizedBox(height: 10),
            _FeedCarousel(
              items: _demoFeed,
              onTapItem: (item) => _openFeedItem(context, item),
            ),

            const SizedBox(height: 20),
            const _SectionTitle('Учёба'),
            const SizedBox(height: 10),
            _ExamsBanner(onTap: () => context.push('/exams')),
          ],
        ),
      ),
    );
  }

  Future<void> _openFeedItem(BuildContext context, FeedItem item) async {
    if (item.url != null) {
      final uri = Uri.parse(item.url!);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть: ${item.url}')),
        );
      }
      return;
    }
    if (item.route != null) {
      if (context.mounted) context.push(item.route!);
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Элемент: ${item.title}')),
      );
    }
  }
}

// =================== HEADER ===================

class _Header extends StatelessWidget {
  final String fullName;
  final String university;
  final String groupName;
  final String status;
  final String? avatarUrl;

  const _Header({
    required this.fullName,
    required this.university,
    required this.groupName,
    required this.status,
    required this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    ImageProvider? avatarProvider;
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      avatarProvider = NetworkImage(avatarUrl!);
    }

    return Column(
      children: [
        CircleAvatar(
          radius: 44,
          backgroundColor: Colors.deepPurple.shade100,
          backgroundImage: avatarProvider,
          child: avatarProvider == null
              ? const Icon(Icons.person, size: 44)
              : null,
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              fullName,
              style: text.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.black,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.verified, size: 18, color: Colors.deepPurple),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          university.isEmpty && groupName.isEmpty
              ? 'Данные профиля не заполнены'
              : [
                  if (university.isNotEmpty) university,
                  if (groupName.isNotEmpty) 'группа $groupName',
                ].join(', '),
          style: text.bodyMedium?.copyWith(color: Colors.black54),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          status.isEmpty ? 'Статус не указан' : status,
          style: text.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// =================== METRICS ===================

class _MetricsRow extends StatelessWidget {
  final String messages;
  final String rating;
  final String friends;

  const _MetricsRow({
    required this.messages,
    required this.rating,
    required this.friends,
  });

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.primary.withOpacity(.08);

    Widget cell(IconData icon, String label, String value) {
      return Expanded(
        child: Column(
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          cell(Icons.chat_bubble_outline, 'Сообщения', messages),
          const SizedBox(width: 12),
          cell(Icons.grade_outlined, 'Рейтинг', rating),
          const SizedBox(width: 12),
          cell(Icons.group_outlined, 'Друзья', friends),
        ],
      ),
    );
  }
}

// =================== FEED / CAROUSEL ===================

class FeedItem {
  final String title;
  final String subtitle;
  final List<Color> gradient;
  final String? route;
  final String? url;

  FeedItem({
    required this.title,
    required this.subtitle,
    required this.gradient,
    this.route,
    this.url,
  });
}

final List<FeedItem> _demoFeed = [
  FeedItem(
    title: 'О нас',
    subtitle: 'Команда Студент Платформ',
    gradient: [const Color(0xFF6D5DF6), const Color(0xFF9A7BFF)],
    url: 'https://example.com/about',
  ),
  FeedItem(
    title: 'Расписание занятий',
    subtitle: 'Твое расписание всегда под рукой',
    gradient: [const Color(0xFF5DB2F6), const Color(0xFF7BD2FF)],
    route: '/schedule',
  ),
  FeedItem(
    title: 'Скидки для студентов',
    subtitle: 'Обновляем лучшие предложения',
    gradient: [const Color(0xFF6AC38F), const Color(0xFF8DE4B0)],
    url: 'https://example.com/discounts',
  ),
];

class _FeedCarousel extends StatefulWidget {
  final List<FeedItem> items;
  final void Function(FeedItem) onTapItem;
  const _FeedCarousel({required this.items, required this.onTapItem});

  @override
  State<_FeedCarousel> createState() => _FeedCarouselState();
}

class _FeedCarouselState extends State<_FeedCarousel> {
  final PageController _controller = PageController(viewportFraction: .92);
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;

    return Column(
      children: [
        SizedBox(
          height: 160,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _index = i),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final it = items[i];
              return GestureDetector(
                onTap: () => widget.onTapItem(it),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(
                      colors: it.gradient,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: it.gradient.last.withOpacity(.35),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              it.subtitle,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13.5,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        _DotsIndicator(length: items.length, index: _index),
      ],
    );
  }
}

class _DotsIndicator extends StatelessWidget {
  final int length;
  final int index;
  const _DotsIndicator({required this.length, required this.index});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 6,
          width: active ? 18 : 6,
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade400,
            borderRadius: BorderRadius.circular(12),
          ),
        );
      }),
    );
  }
}

// =================== EXAMS BANNER ===================

class _ExamsBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _ExamsBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = [
      Theme.of(context).colorScheme.primary.withOpacity(.12),
      Theme.of(context).colorScheme.primary.withOpacity(.2),
    ];
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.last.withOpacity(.25),
              blurRadius: 16,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.school_outlined, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Зачёты и экзамены',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

// =================== UTILS ===================

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}
