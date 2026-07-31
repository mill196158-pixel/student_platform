import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors SubjectInfoScreen cache-first bootstrap:
/// paint [_cachedPaint] immediately, then replace with network result.
void main() {
  testWidgets('cache paints first then network replaces body', (tester) async {
    final network = Completer<String>();
    var networkStarted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: _BootstrapHost(
          loadCached: () => Future<String?>.value('cached-card'),
          loadNetwork: () async {
            networkStarted = true;
            return network.future;
          },
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(find.text('cached-card'), findsOneWidget);
    expect(networkStarted, isTrue);

    network.complete('fresh-card');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
      if (find.text('fresh-card').evaluate().isNotEmpty) break;
    }
    expect(find.text('fresh-card'), findsOneWidget);
    expect(find.text('cached-card'), findsNothing);
  });
}

class _BootstrapHost extends StatefulWidget {
  const _BootstrapHost({
    required this.loadCached,
    required this.loadNetwork,
  });

  final Future<String?> Function() loadCached;
  final Future<String> Function() loadNetwork;

  @override
  State<_BootstrapHost> createState() => _BootstrapHostState();
}

class _BootstrapHostState extends State<_BootstrapHost> {
  String? _cachedPaint;
  String? _freshPaint;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final cached = await widget.loadCached();
    if (cached != null && mounted) {
      setState(() => _cachedPaint = cached);
    }
    final next = await widget.loadNetwork();
    if (!mounted) return;
    setState(() {
      _cachedPaint = null;
      _freshPaint = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = _freshPaint ?? _cachedPaint;
    if (text == null) {
      return const CircularProgressIndicator();
    }
    return Text(text);
  }
}
