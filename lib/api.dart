import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

/// Talks to one snippet `serve` daemon. The token is passed as a `?token=` query
/// param on every request (matching the daemon's auth) and the session id (a
/// path with a `/`) is URL-encoded automatically by [Uri].
class DaemonClient {
  final String baseUrl; // e.g. https://abc.trycloudflare.com
  final String token;

  DaemonClient(this.baseUrl, this.token);

  Uri _uri(String path, [Map<String, String>? extra]) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      path: path,
      queryParameters: {'token': token, ...?extra},
    );
  }

  Future<bool> health() async {
    try {
      final r = await http
          .get(_uri('/health'))
          .timeout(const Duration(seconds: 12));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<SessionInfo>> sessions() async {
    final r = await http.get(_uri('/sessions'));
    if (r.statusCode != 200) throw _err('list sessions', r);
    final list = jsonDecode(r.body) as List;
    return list
        .map((e) => SessionInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<FsListing> fs(String? path) async {
    final r = await http.get(_uri('/fs', path == null ? null : {'path': path}));
    if (r.statusCode != 200) throw _err('browse', r);
    return FsListing.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<String> openSession(String folder, {bool resume = true}) async {
    final r = await http.post(
      _uri('/sessions'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'folder': folder, 'resume': resume}),
    );
    if (r.statusCode != 200) throw _err('open session', r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  WebSocketChannel attach(String sessionId) {
    final base = Uri.parse(baseUrl);
    final wsScheme = base.scheme == 'https' ? 'wss' : 'ws';
    final uri = base.replace(
      scheme: wsScheme,
      path: '/attach',
      queryParameters: {'session': sessionId, 'token': token},
    );
    return WebSocketChannel.connect(uri);
  }

  String _err(String what, http.Response r) =>
      'Failed to $what (HTTP ${r.statusCode})${r.body.isNotEmpty ? ': ${r.body}' : ''}';
}
