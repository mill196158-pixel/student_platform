import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores presentation preferences on this device, separately per account.
class DiaryExpansionState extends StatefulWidget {
  const DiaryExpansionState(
      {super.key,
      required this.userId,
      required this.section,
      required this.initiallyExpanded,
      required this.builder});

  final String? userId;
  final String section;
  final bool initiallyExpanded;
  final Widget Function(BuildContext, bool, ValueChanged<bool>) builder;

  @override
  State<DiaryExpansionState> createState() => _DiaryExpansionStateState();
}

class _DiaryExpansionStateState extends State<DiaryExpansionState> {
  late Future<SharedPreferences?> _preferences;

  @override
  void initState() {
    super.initState();
    _preferences = _load();
  }

  Future<SharedPreferences?> _load() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.userId?.trim();
    final storageKey = userId == null || userId.isEmpty
        ? null
        : 'personal_diary_expansion_v1_${userId}_${widget.section}';
    if (storageKey == null) {
      return widget.builder(context, widget.initiallyExpanded, (_) {});
    }
    return FutureBuilder<SharedPreferences?>(
      future: _preferences,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(height: 72);
        }
        final prefs = snapshot.data;
        bool expanded = widget.initiallyExpanded;
        try {
          expanded = prefs?.getBool(storageKey) ?? expanded;
        } catch (_) {
          // A corrupt preference must not prevent opening the diary.
        }
        return widget.builder(context, expanded, (value) {
          if (prefs != null) {
            unawaited(prefs
                .setBool(storageKey, value)
                .catchError((Object _) => false));
          }
        });
      },
    );
  }
}
