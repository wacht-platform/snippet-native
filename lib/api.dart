import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  Future<bool> health({Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final r = await http.get(_uri('/health')).timeout(timeout);
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

  /// The current message attachments are uploaded before send; audio is
  /// transcribed by the daemon after the message arrives.
  /// Upload [bytes]. With [dir] set, saves into that directory under [name]
  /// (file-explorer upload); otherwise a temp path (chat attachment).
  Future<String> uploadFile(List<int> bytes,
      {String? name, String? dir}) async {
    final body = <String, dynamic>{'data_base64': base64Encode(bytes)};
    if (name != null && name.isNotEmpty) body['name'] = name;
    if (dir != null && dir.isNotEmpty) body['dir'] = dir;
    final r = await http.post(_uri('/fs/upload'),
        headers: _json, body: jsonEncode(body));
    if (r.statusCode != 200) throw _err('upload', r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['path'] as String;
  }

  Future<String> openSession(String folder,
      {bool resume = true,
      String? profile,
      bool newConversation = false}) async {
    final body = <String, dynamic>{'folder': folder, 'resume': resume};
    if (newConversation) body['new_conversation'] = true;
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
    bool? stream,
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
    // '' is meaningful: the daemon clears the effort on an explicit empty
    // string and keeps the current value when the field is omitted.
    if (reasoningEffort != null) {
      body['reasoning_effort'] = reasoningEffort;
    }
    if (supportsImages != null) body['supports_images'] = supportsImages;
    if (contextWindow != null && contextWindow > 0)
      body['context_window'] = contextWindow;
    if (stream != null) body['stream'] = stream;
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

  /// Live model catalog from the provider's own models API (the key stays on
  /// the daemon). For a saved profile pass [name]; for an editor draft pass
  /// provider/baseUrl/apiKey — a stored key is used when [apiKey] is empty.
  Future<List<CatalogModel>> providerModels(
      {String? name, String? provider, String? baseUrl, String? apiKey}) async {
    final body = <String, dynamic>{};
    if (name != null && name.isNotEmpty) body['name'] = name;
    if (provider != null && provider.isNotEmpty) body['provider'] = provider;
    if (baseUrl != null && baseUrl.isNotEmpty) body['base_url'] = baseUrl;
    if (apiKey != null && apiKey.isNotEmpty) body['api_key'] = apiKey;
    final r = await http.post(_uri('/provider/models'),
        headers: _json, body: jsonEncode(body));
    if (r.statusCode != 200) throw _err('list models', r);
    return ((jsonDecode(r.body) as Map<String, dynamic>)['models'] as List? ??
            const [])
        .map((e) => CatalogModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Vault: names only ever come back; values only ever go up.
  Future<List<String>> vaultList() async {
    final r = await http.get(_uri('/vault'));
    if (r.statusCode != 200) throw _err('vault', r);
    return ((jsonDecode(r.body) as Map<String, dynamic>)['names'] as List? ??
            const [])
        .cast<String>();
  }

  Future<void> vaultSet(String name, String value) async {
    final r = await http.put(_uri('/vault'),
        headers: _json, body: jsonEncode({'name': name, 'value': value}));
    if (r.statusCode != 200) throw _err('vault set', r);
  }

  Future<void> vaultDelete(String name) async {
    final r = await http.delete(_uri('/vault', {'name': name}));
    if (r.statusCode != 200) throw _err('vault delete', r);
  }

  /// Begin xAI (Grok/X subscription) device-code sign-in. Returns the user code
  /// and verification URL to show; the daemon polls for approval in the background.
  Future<({String userCode, String verificationUri})> xaiLoginBegin() async {
    final r = await http.post(_uri('/xai/login'), headers: _json);
    if (r.statusCode != 200) throw _err('xai login', r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      userCode: j['user_code'] as String,
      verificationUri: j['verification_uri'] as String
    );
  }

  Future<bool> xaiSignedIn() async {
    final r = await http.get(_uri('/xai/status'));
    if (r.statusCode != 200) return false;
    return (jsonDecode(r.body) as Map<String, dynamic>)['signed_in'] == true;
  }

  Future<void> xaiLogout() async {
    await http.post(_uri('/xai/logout'), headers: _json);
  }

  /// Set the profile delegated lanes run on. Pass null/'' to clear (delegation
  /// falls back to the active model).
  Future<void> setDelegateProfile(String? name) async {
    final r = await http.post(_uri('/config/delegate'),
        headers: _json, body: jsonEncode({'name': name ?? ''}));
    if (r.statusCode != 200) throw _err('set delegate', r);
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
        headers: _json,
        body: jsonEncode({'session': sessionId, 'title': title}));
    if (r.statusCode != 200) throw _err('rename session', r);
  }

  Future<Map<String, dynamic>> exec(String sessionId, String command) async {
    final r = await http.post(_uri('/session/exec'),
        headers: _json,
        body: jsonEncode({'session': sessionId, 'command': command}));
    if (r.statusCode != 200) throw _err('run command', r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Atomic write with optimistic concurrency. Returns the daemon's JSON:
  /// {ok, hash, size} on success, or {ok:false, conflict:true, error} (HTTP 409)
  /// when the file changed on disk since [prevHash] was read.
  Future<Map<String, dynamic>> writeFile(String path, String content,
      {String? prevHash}) async {
    final body = <String, dynamic>{
      'path': path,
      'content': content,
      if (prevHash != null) 'prev_hash': prevHash,
    };
    final r = await http.post(_uri('/fs/write'),
        headers: _json, body: jsonEncode(body));
    if (r.statusCode == 200 || r.statusCode == 409) {
      return jsonDecode(r.body) as Map<String, dynamic>;
    }
    throw _err('save file', r);
  }

  /// Create a new directory at [path]. Throws on conflict/error.
  Future<void> mkdir(String path) async {
    final r = await http.post(_uri('/fs/mkdir'),
        headers: _json, body: jsonEncode({'path': path}));
    if (r.statusCode != 200) throw _err('create folder', r);
  }

  /// Delete a file or directory (directories are removed recursively).
  Future<void> deletePath(String path) async {
    final r = await http.post(_uri('/fs/delete'),
        headers: _json, body: jsonEncode({'path': path}));
    if (r.statusCode != 200) throw _err('delete', r);
  }

  /// Download a file's raw bytes (any type, up to the daemon's cap).
  /// Absolute URL (with the auth token) for streaming or displaying a file —
  /// used by Image.network and the video player. The daemon serves a real
  /// content-type and honors Range requests, so media streams/seeks.
  String fileUrl(String path) =>
      _uri('/fs/download', {'path': path}).toString();

  /// Stream a file to [output] without buffering the whole response in memory.
  /// [onProgress] receives bytes received and the optional content length.
  Future<File> downloadToFile(
    String path,
    File output, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final httpClient = http.Client();
    try {
      final request = http.Request('GET', _uri('/fs/download', {'path': path}));
      final response =
          await httpClient.send(request).timeout(const Duration(minutes: 5));
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw Exception(
            'Failed to download (HTTP ${response.statusCode})${body.isNotEmpty ? ': $body' : ''}');
      }
      await output.parent.create(recursive: true);
      final sink = output.openWrite();
      var received = 0;
      try {
        await for (final chunk
            in response.stream.timeout(const Duration(minutes: 5))) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, response.contentLength);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return output;
    } catch (_) {
      try {
        if (await output.exists()) await output.delete();
      } catch (_) {}
      rethrow;
    } finally {
      httpClient.close();
    }
  }

  Future<Uint8List> downloadFile(String path) async {
    final r = await http.get(_uri('/fs/download', {'path': path}));
    if (r.statusCode != 200) throw _err('download', r);
    return r.bodyBytes;
  }

  // ---- git (server-side, scoped to a session's workspace) ----

  Future<Map<String, dynamic>> _gitPost(
      String op, Map<String, dynamic> body) async {
    final r = await http.post(_uri('/git/$op'),
        headers: _json, body: jsonEncode(body));
    if (r.statusCode != 200) throw _err('git $op', r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<GitStatus> gitStatus(String session) async =>
      GitStatus.fromJson(await _gitPost('status', {'session': session}));

  Future<String> gitDiff(String session,
      {String? file, bool staged = false, bool untracked = false}) async {
    final d = await _gitPost('diff', {
      'session': session,
      if (file != null) 'file': file,
      'staged': staged,
      'untracked': untracked,
    });
    return d['patch'] as String? ?? '';
  }

  Future<List<GitCommit>> gitLog(String session, {int limit = 50}) async {
    final d = await _gitPost('log', {'session': session, 'limit': limit});
    return ((d['commits'] as List?) ?? [])
        .map((e) => GitCommit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Returns (current branch, all local branches).
  Future<(String, List<String>)> gitBranches(String session) async {
    final d = await _gitPost('branches', {'session': session});
    return (
      d['current'] as String? ?? '',
      ((d['branches'] as List?) ?? const []).map((e) => e as String).toList(),
    );
  }

  Future<Map<String, dynamic>> gitStage(String session,
          {List<String>? paths, bool all = false}) =>
      _gitPost('stage',
          {'session': session, if (paths != null) 'paths': paths, 'all': all});

  Future<Map<String, dynamic>> gitUnstage(String session,
          {List<String>? paths}) =>
      _gitPost(
          'unstage', {'session': session, if (paths != null) 'paths': paths});

  Future<Map<String, dynamic>> gitCommit(String session, String message,
          {bool amend = false}) =>
      _gitPost(
          'commit', {'session': session, 'message': message, 'amend': amend});

  Future<Map<String, dynamic>> gitCheckout(String session, String target,
          {bool create = false}) =>
      _gitPost(
          'checkout', {'session': session, 'target': target, 'create': create});

  Future<List<Map<String, dynamic>>> bgList(String session) async {
    final r = await http.post(_uri('/bg'),
        headers: _json, body: jsonEncode({'session': session}));
    if (r.statusCode != 200) throw _err('list processes', r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final procs = (j['processes'] as List?) ?? const [];
    return procs.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  Future<void> bgKill(String session, String id) async {
    final r = await http.post(_uri('/bg/kill'),
        headers: _json, body: jsonEncode({'session': session, 'id': id}));
    if (r.statusCode != 200) throw _err('stop process', r);
  }

  Future<String> bgLog(String session, String id, {int tail = 300}) async {
    final r = await http.post(_uri('/bg/log'),
        headers: _json,
        body: jsonEncode({'session': session, 'id': id, 'tail': tail}));
    if (r.statusCode != 200) throw _err('read log', r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return j['log'] as String? ?? '';
  }

  Future<Map<String, dynamic>> gitPush(String session) =>
      _gitPost('push', {'session': session});

  Future<Map<String, dynamic>> gitPull(String session) =>
      _gitPost('pull', {'session': session});

  Future<Map<String, dynamic>> gitStash(String session, String op) =>
      _gitPost('stash', {'session': session, 'op': op});

  String _err(String what, http.Response r) =>
      'Failed to $what (HTTP ${r.statusCode})${r.body.isNotEmpty ? ': ${r.body}' : ''}';
}
