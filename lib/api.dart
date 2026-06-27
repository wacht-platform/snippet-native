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

  Map<String, String> get _json => {'content-type': 'application/json'};

  Future<bool> health() async {
    try {
      final r =
          await http.get(_uri('/health')).timeout(const Duration(seconds: 12));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<SessionInfo>> sessions({String? folder, int? limit}) async {
    final q = <String, String>{};
    if (folder != null) q['folder'] = folder;
    if (limit != null) q['limit'] = '$limit';
    final r = await http.get(_uri('/sessions', q.isEmpty ? null : q));
    if (r.statusCode != 200) throw _err('list sessions', r);
    final list = jsonDecode(r.body) as List;
    return list
        .map((e) => SessionInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// {folder: session count} across the device — for per-folder badges without
  /// downloading the whole session list.
  Future<Map<String, int>> sessionCounts() async {
    final r = await http.get(_uri('/sessions/counts'));
    if (r.statusCode != 200) throw _err('session counts', r);
    return (jsonDecode(r.body) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, (v as num).toInt()));
  }

  Future<FsListing> fs(String? path) async {
    final r = await http.get(_uri('/fs', path == null ? null : {'path': path}));
    if (r.statusCode != 200) throw _err('browse', r);
    return FsListing.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<FileContent> readFile(String path) async {
    final r = await http.get(_uri('/fs/file', {'path': path}));
    if (r.statusCode != 200) throw _err('read file', r);
    return FileContent.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Upload image/file bytes; returns the absolute path on the daemon (which the
  /// agent can then view with read_image).
  Future<String> uploadFile(List<int> bytes, {String? name}) async {
    final body = <String, dynamic>{'data_base64': base64Encode(bytes)};
    if (name != null && name.isNotEmpty) body['name'] = name;
    final r = await http.post(_uri('/fs/upload'), headers: _json, body: jsonEncode(body));
    if (r.statusCode != 200) throw _err('upload', r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['path'] as String;
  }

  Future<String> openSession(String folder,
      {bool resume = true, String? profile}) async {
    final body = <String, dynamic>{'folder': folder, 'resume': resume};
    if (profile != null && profile.isNotEmpty) body['profile'] = profile;
    final r = await http.post(_uri('/sessions'),
        headers: _json, body: jsonEncode(body));
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

  // ---- model configuration (shared with the TUI's config.toml) ----

  Future<ServerConfig> getConfig() async {
    final r = await http.get(_uri('/config'));
    if (r.statusCode != 200) throw _err('load config', r);
    return ServerConfig.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<String> putProfile({
    String? name,
    required String provider,
    String? baseUrl,
    required String model,
    String? apiKey,
    String? reasoningEffort,
    bool? supportsImages,
    int? contextWindow,
    bool setActive = false,
  }) async {
    final body = <String, dynamic>{
      'provider': provider,
      'model': model,
      'set_active': setActive,
    };
    if (name != null && name.isNotEmpty) body['name'] = name;
    if (baseUrl != null && baseUrl.isNotEmpty) body['base_url'] = baseUrl;
    if (apiKey != null && apiKey.isNotEmpty) body['api_key'] = apiKey;
    if (reasoningEffort != null && reasoningEffort.isNotEmpty) {
      body['reasoning_effort'] = reasoningEffort;
    }
    if (supportsImages != null) body['supports_images'] = supportsImages;
    if (contextWindow != null && contextWindow > 0) body['context_window'] = contextWindow;
    final r = await http.put(_uri('/config/profile'),
        headers: _json, body: jsonEncode(body));
    if (r.statusCode != 200) throw _err('save profile', r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['name'] as String;
  }

  Future<void> setActiveProfile(String name) async {
    final r = await http.post(_uri('/config/active'),
        headers: _json, body: jsonEncode({'name': name}));
    if (r.statusCode != 200) throw _err('set active', r);
  }

  Future<void> deleteProfile(String name) async {
    final r = await http.delete(_uri('/config/profile', {'name': name}));
    if (r.statusCode != 200) throw _err('delete profile', r);
  }

  Future<void> setSessionModel(String sessionId, String profile) async {
    final r = await http.post(_uri('/session/model'),
        headers: _json,
        body: jsonEncode({'session': sessionId, 'profile': profile}));
    if (r.statusCode != 200) throw _err('switch model', r);
  }

  Future<void> rewind(String sessionId, String checkpoint) async {
    final r = await http.post(_uri('/session/rewind'),
        headers: _json,
        body: jsonEncode({'session': sessionId, 'checkpoint': checkpoint}));
    if (r.statusCode != 200) throw _err('rewind', r);
  }

  Future<void> deleteSession(String sessionId) async {
    final r = await http.post(_uri('/session/delete'),
        headers: _json, body: jsonEncode({'session': sessionId}));
    if (r.statusCode != 200) throw _err('delete session', r);
  }

  Future<void> renameSession(String sessionId, String title) async {
    final r = await http.post(_uri('/session/rename'),
        headers: _json, body: jsonEncode({'session': sessionId, 'title': title}));
    if (r.statusCode != 200) throw _err('rename session', r);
  }

  Future<Map<String, dynamic>> exec(String sessionId, String command) async {
    final r = await http.post(_uri('/session/exec'),
        headers: _json,
        body: jsonEncode({'session': sessionId, 'command': command}));
    if (r.statusCode != 200) throw _err('run command', r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  String _err(String what, http.Response r) =>
      'Failed to $what (HTTP ${r.statusCode})${r.body.isNotEmpty ? ': ${r.body}' : ''}';
}
