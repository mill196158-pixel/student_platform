import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_authorizer.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_document_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Direct, independent resolve: never calls the shared legacy grant API.
class SourceBoundDocumentNetwork {
  const SourceBoundDocumentNetwork(this.client, this.authorizer, this.store);
  final SupabaseClient client;
  final SourceBoundAuthorizer authorizer;
  final SourceBoundDocumentStore store;

  Future<bool> download(
      SourceAttachmentIdentity source, bool Function() current,
      {http.Client Function()? makeHttp,
      Duration resolveTimeout = const Duration(seconds: 15),
      Duration downloadTimeout = const Duration(seconds: 30)}) async {
    SourceAccessGrant? grant;
    http.Client? httpClient;
    try {
      Future<SourceAccessResponse> resolve() async {
        try {
          final response = await client.functions.invoke('chat-file-access',
              body: {'action': 'resolve', 'key': source.fileKey});
          final data = response.data;
          if (data is! Map ||
              data['accessPolicyVersion'] != 1 ||
              data['fileId'] is! String ||
              data['url'] is! String) {
            throw const FormatException('Unexpected access response');
          }
          return SourceAccessResponse.allow(
              fileId: data['fileId'] as String,
              key: source.fileKey,
              signedUrl: data['url'] as String);
        } on FunctionException catch (error) {
          if (error.status == 403 &&
              error.details is Map &&
              (error.details as Map)['error'] == 'file_unavailable' &&
              (error.details as Map)['reason'] == 'access_denied_v1') {
            return const SourceAccessResponse.deny();
          }
          rethrow;
        }
      }

      grant = await authorizer.authorize(source, current, resolve,
          timeout: resolveTimeout);
      if (grant == null || !current()) return false;
      httpClient = makeHttp?.call() ?? http.Client();
      final request = http.Request('GET', grant.signedUrl)
        ..followRedirects = false;
      final elapsed = Stopwatch()..start();
      Duration remaining() {
        final left = downloadTimeout - elapsed.elapsed;
        if (left <= Duration.zero)
          throw TimeoutException('Download deadline exceeded');
        return left;
      }

      final response = await httpClient.send(request).timeout(remaining());
      if (response.statusCode != 200 ||
          !current() ||
          (response.contentLength != null &&
              response.contentLength! > SourceBoundDocumentStore.maxFileBytes))
        return false;
      final out = BytesBuilder(copy: false);
      final stream = StreamIterator<List<int>>(response.stream);
      try {
        while (await stream.moveNext().timeout(remaining())) {
          if (!current() ||
              out.length + stream.current.length >
                  SourceBoundDocumentStore.maxFileBytes) return false;
          out.add(stream.current);
        }
      } finally {
        unawaited(stream.cancel().catchError((Object _) {}));
      }
      if (!current()) return false;
      final second = await authorizer.authorize(source, current, resolve,
          timeout: resolveTimeout);
      if (second == null) return false;
      final matches = second.sequence == grant.sequence &&
          second.snapshotHash == grant.snapshotHash;
      await second.close();
      if (!matches || !current()) return false;
      return await store.publish(source, current, grant, out.takeBytes());
    } catch (_) {
      return false;
    } finally {
      await grant?.close();
      httpClient?.close();
    }
  }
}
