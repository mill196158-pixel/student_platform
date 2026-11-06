import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';

enum HomeContentSection { news, promo }

enum HomeContentLoadStatus { confirmed, denied, unavailable }

class HomeContentLoadResult {
  const HomeContentLoadResult(this.status,
      {this.rows = const [], this.media = const {}});
  final HomeContentLoadStatus status;
  final List<Map<String, dynamic>> rows;
  final Map<String, Uint8List> media;
}

/// Downloads a fresh, authorized snapshot; never reads the legacy caches and
/// never persists signed URLs. The entire operation stays under the barrier.
class HomeContentVerifiedLoader {
  HomeContentVerifiedLoader(
      {required this.client,
      required this.httpClient,
      required this.scope,
      required this.owner,
      required this.barrier,
      required this.project,
      required this.onAuthorizationDenial});
  final SupabaseClient client;
  final http.Client httpClient;
  final AuthSessionScope scope;
  final AuthOperationScope owner;
  final OnlineSideEffectBarrier barrier;
  final Uri project;

  /// Persists quarantine under the captured owner, even if the barrier closes
  /// while the response is in flight. Must not dispatch a new network call.
  final Future<void> Function() onAuthorizationDenial;
  bool get _current {
    try {
      final trusted = Uri.parse(SupabaseConfig.url);
      return trusted.scheme == 'https' &&
          trusted.userInfo.isEmpty &&
          trusted.origin == project.origin &&
          project.path.isEmpty &&
          project.query.isEmpty &&
          project.fragment.isEmpty &&
          identical(client, SupabaseConfig.client) &&
          client.accessToken == null &&
          scope.matchesSession(owner, client.auth.currentSession) &&
          scope.bindingFor(owner, '${trusted.origin}/auth/v1') != null &&
          barrier.isOpen;
    } catch (_) {
      return false;
    }
  }

  Future<HomeContentLoadResult> load(HomeContentSection section) async {
    final result = await barrier.run(() => _load(section));
    return result ??
        const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
  }

  Future<HomeContentLoadResult> _load(HomeContentSection section) async {
    if (!_current)
      return const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
    try {
      final dynamic raw = section == HomeContentSection.news
          ? await client.rpc('get_my_published_news')
          : await client.rpc('get_my_content_for_placement',
              params: {'p_placement': 'home_promo'});
      if (!_current || raw is! List || raw.length >= 1000) {
        return const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
      }
      if (raw.length > 50) {
        return const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
      }
      final rows = <Map<String, dynamic>>[], media = <String, Uint8List>{};
      var totalBytes = 0;
      final ids = <String>{};
      for (final value in raw) {
        if (value is! Map || value.keys.any((key) => key is! String)) {
          return const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
        }
        final row = Map<String, dynamic>.from(value);
        final id = row['id'];
        if (id is! String || id.isEmpty || !ids.add(id)) {
          return const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
        }
        final assets = <(String, String)>[];
        late final Map<String, dynamic> safeRow;
        if (section == HomeContentSection.news) {
          if (row['title'] is! String ||
              row['created_at'] is! String ||
              DateTime.tryParse(row['created_at'] as String) == null) {
            return const HomeContentLoadResult(
                HomeContentLoadStatus.unavailable);
          }
          final path = row['image_path'];
          if (path != null && (path is! String || path.isEmpty)) {
            return const HomeContentLoadResult(
                HomeContentLoadStatus.unavailable);
          }
          if (path is String) assets.add(('news:$id', path));
          const allowed = {
            'id',
            'title',
            'subtitle',
            'body',
            'variant',
            'gradient_colors',
            'image_focus_x',
            'image_focus_y',
            'overlay_opacity',
            'published_at',
            'created_at',
            'updated_at',
            'priority'
          };
          safeRow = Map.fromEntries(
              row.entries.where((entry) => allowed.contains(entry.key)));
        } else {
          final card = ManagedContentCard.tryParseHomePromo(row);
          if (card == null)
            return const HomeContentLoadResult(
                HomeContentLoadStatus.unavailable);
          final image = card.homePromo.imageAssetId,
              icon = card.homePromo.iconAssetId;
          if (image != null && image.isNotEmpty)
            assets.add(('promo:$id:image', image));
          if (icon != null && icon.isNotEmpty)
            assets.add(('promo:$id:icon', icon));
          final payload = card.homePromo.toWireJson()
            ..remove('action')
            ..remove('cta_url')
            ..remove('cta_route');
          safeRow = {
            'id': id,
            'template_key': card.templateKey,
            'schema_version': card.schemaVersion,
            'origin': row['origin'],
            'placement': 'home_promo',
            'sort_order': card.sortOrder,
            'priority': card.priority,
            'payload': payload
          };
        }
        for (final asset in assets) {
          final fetched = await _fetch(section, asset.$2);
          if (!_current)
            return const HomeContentLoadResult(
                HomeContentLoadStatus.unavailable);
          if (fetched.status != HomeContentLoadStatus.confirmed)
            return HomeContentLoadResult(fetched.status);
          final bytes = fetched.bytes!;
          totalBytes += bytes.length;
          if (totalBytes > 16 * 1024 * 1024) {
            return const HomeContentLoadResult(
                HomeContentLoadStatus.unavailable);
          }
          final mediaKey = '${asset.$1}:${sha256.convert(bytes)}';
          media[mediaKey] = bytes;
          safeRow[asset.$1.endsWith(':icon')
              ? '_offline_icon'
              : '_offline_image'] = mediaKey;
        }
        rows.add(safeRow);
      }
      return HomeContentLoadResult(HomeContentLoadStatus.confirmed,
          rows: rows, media: media);
    } on FunctionException catch (error) {
      if (error.status == 401 || error.status == 403) {
        await barrier.trackTeardown(onAuthorizationDenial);
        return const HomeContentLoadResult(HomeContentLoadStatus.denied);
      }
      return const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
    } catch (_) {
      return const HomeContentLoadResult(HomeContentLoadStatus.unavailable);
    }
  }

  Future<_MediaResult> _fetch(HomeContentSection section, String asset) async {
    if (!_current) return const _MediaResult(HomeContentLoadStatus.unavailable);
    final response = await client.functions.invoke(
        section == HomeContentSection.news ? 'news-media' : 'content-media',
        body: section == HomeContentSection.news
            ? {'action': 'createDownload', 'path': asset}
            : {'action': 'createDownload', 'assetId': asset});
    if (response.status == 401 || response.status == 403) {
      await barrier.trackTeardown(onAuthorizationDenial);
      return const _MediaResult(HomeContentLoadStatus.denied);
    }
    if (!_current) return const _MediaResult(HomeContentLoadStatus.unavailable);
    final data = response.data;
    if (response.status != 200 ||
        data is! Map ||
        data['signedUrl'] is! String) {
      return const _MediaResult(HomeContentLoadStatus.unavailable);
    }
    final url = Uri.tryParse(data['signedUrl'] as String);
    if (url == null ||
        url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        url.origin != project.origin) {
      return const _MediaResult(HomeContentLoadStatus.unavailable);
    }
    if (!_current) return const _MediaResult(HomeContentLoadStatus.unavailable);
    final request = http.Request('GET', url)..followRedirects = false;
    final download = await httpClient.send(request);
    // A Storage denial can mean an expired signed URL, not revoked access.
    // Do not quarantine a previously authorised snapshot on that basis.
    if (download.statusCode == 401 || download.statusCode == 403)
      return const _MediaResult(HomeContentLoadStatus.unavailable);
    if (!_current || download.statusCode != 200)
      return const _MediaResult(HomeContentLoadStatus.unavailable);
    final bytes = <int>[];
    await for (final chunk in download.stream) {
      if (!_current || bytes.length + chunk.length > 8 * 1024 * 1024) {
        return const _MediaResult(HomeContentLoadStatus.unavailable);
      }
      bytes.addAll(chunk);
    }
    if (!_current || bytes.isEmpty)
      return const _MediaResult(HomeContentLoadStatus.unavailable);
    return _MediaResult(
        HomeContentLoadStatus.confirmed, Uint8List.fromList(bytes));
  }
}

class _MediaResult {
  const _MediaResult(this.status, [this.bytes]);
  final HomeContentLoadStatus status;
  final Uint8List? bytes;
}
