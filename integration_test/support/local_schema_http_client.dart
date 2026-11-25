import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const localSupabaseUrl = 'http://127.0.0.1:55321';

// Keep GoTrue on its normal local API. Route PostgREST to this run's isolated
// server so other native E2Es can use their own schemas at the same time.
class LocalSchemaHttpClient extends http.BaseClient {
  LocalSchemaHttpClient(this.port);
  final int port;
  final _client = IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != localSupabaseUrl)
      throw StateError('Non-local host');
    const prefix = '/rest/v1';
    if (!request.url.path.startsWith('$prefix/')) return _client.send(request);
    final uri = request.url
        .replace(port: port, path: request.url.path.substring(prefix.length));
    final forwarded = http.Request(request.method, uri)
      ..followRedirects = false
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    return _client.send(forwarded);
  }

  @override
  void close() => _client.close();
}
