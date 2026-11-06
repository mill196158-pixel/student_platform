import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/cached_document_open.dart';

void main() {
  test('opens authorized cached path without making an export copy', () async {
    var calls = 0;
    var exports = 0;
    final opened = await openDocumentWithFallback(
      isCurrent: () => true,
      cachedPath: () async => '/private/cache/object',
      openCached: (path) async {
        calls++;
        expect(path, '/private/cache/object');
        return true;
      },
      exportPath: () async { exports++; return '/copy'; },
      openExport: (_) async => true,
      resolveUrl: () async => null,
      launchUrl: (_) async => true,
    );
    expect(opened, isTrue);
    expect(calls, 1);
    expect(exports, 0);
  });

  test('session or file change during lookup prevents external open', () async {
    var current = true;
    var calls = 0;
    final lookup = Completer<String?>();
    final pending = tryOpenCachedDocument(
      isCurrent: () => current,
      cachedPath: () => lookup.future,
      open: (_) async {
        calls++;
        return true;
      },
    );
    current = false;
    lookup.complete('/private/cache/object');
    expect(await pending, isFalse);
    expect(calls, 0);
  });

  for (final operation in ['download fallback', 'URL resolution']) {
    test('$operation does not hand off after session or file change', () async {
      var current = true;
      var handoffs = 0;
      final delayed = Completer<String?>();
      final result = openDocumentWithFallback(
        isCurrent: () => current,
        cachedPath: () async => null,
        openCached: (_) async => false,
        exportPath: () => operation == 'download fallback'
            ? delayed.future
            : Future<String?>.value(null),
        openExport: (_) async {
          handoffs++;
          return true;
        },
        resolveUrl: () => operation == 'URL resolution'
            ? delayed.future
            : Future<String?>.value(null),
        launchUrl: (_) async {
          handoffs++;
          return true;
        },
      );
      // Allow the preceding missed stages to complete and reach the delay.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      current = false;
      delayed.complete(operation == 'URL resolution'
          ? 'https://example.test/file'
          : '/private/cache/export.pdf');
      expect(await result, isFalse);
      expect(handoffs, 0);
    });
  }

  test('missing cache or rejected viewer asks caller to use fallback', () async {
    expect(
      await tryOpenCachedDocument(
        isCurrent: () => true,
        cachedPath: () async => null,
        open: (_) async => throw StateError('must not open'),
      ),
      isFalse,
    );
    expect(
      await tryOpenCachedDocument(
        isCurrent: () => true,
        cachedPath: () async => '/private/cache/object',
        open: (_) async => false,
      ),
      isFalse,
    );
  });

  test('rejected export viewer falls back to the resolved URL', () async {
    var launches = 0;
    final opened = await openDocumentWithFallback(
      isCurrent: () => true,
      cachedPath: () async => null,
      openCached: (_) async => false,
      exportPath: () async => '/private/cache/export.pdf',
      openExport: (_) async => false,
      resolveUrl: () async => 'https://example.test/file',
      launchUrl: (_) async { launches++; return true; },
    );
    expect(opened, isTrue);
    expect(launches, 1);
  });
}
