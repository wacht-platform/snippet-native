// Dart models mirroring the snippet `serve` daemon wire shapes. Fields the daemon
// omits when empty/None are treated as optional here.

/// A saved daemon connection (one `snippet serve` instance).
class Instance {
  final String name;
  final String url;
  final String token;
  const Instance({required this.name, required this.url, required this.token});

  factory Instance.fromJson(Map<String, dynamic> j) => Instance(
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        token: j['token'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'name': name, 'url': url, 'token': token};

  String get label => name.isEmpty ? hostOf(url) : name;
}

String hostOf(String url) {
  try {
    final h = Uri.parse(url).host;
    return h.isEmpty ? url : h;
  } catch (_) {
    return url;
  }
}

class SessionInfo {
  final String id;
  final String folder;
  final String conversation;
  final String title;
  final String status;
  final int lastActive;
  final bool running;

  SessionInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        folder = j['folder'] as String? ?? '',
        conversation = j['conversation'] as String? ?? '',
        title = j['title'] as String? ?? '',
        status = j['status'] as String? ?? '',
        lastActive = (j['last_active'] as num?)?.toInt() ?? 0,
        running = j['running'] == true;
}

class FsEntry {
  final String name;
  final String path;
  final bool isDir;
  final bool git;

  FsEntry.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String? ?? '',
        path = j['path'] as String? ?? '',
        isDir = j['is_dir'] == true,
        git = j['git'] == true;
}

class FsListing {
  final String path;
  final String? parent;
  final List<FsEntry> entries;

  FsListing.fromJson(Map<String, dynamic> j)
      : path = j['path'] as String? ?? '',
        parent = j['parent'] as String?,
        entries = ((j['entries'] as List?) ?? const [])
            .map((e) => FsEntry.fromJson(e as Map<String, dynamic>))
            .toList();
}

class HarnessState {
  final String status;
  final String workspace;
  final String userRequest;
  final List<Map<String, dynamic>> events;
  final String? finalText;
  final String approvalMode;
  final Map<String, dynamic>? pendingQuestion;
  final int totalTokens;
  final int lastPromptTokens;

  HarnessState.fromJson(Map<String, dynamic> j)
      : status = j['status'] as String? ?? 'idle',
        workspace = j['workspace'] as String? ?? '',
        userRequest = j['user_request'] as String? ?? '',
        events = ((j['events'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList(),
        finalText = j['final_text'] as String?,
        approvalMode = j['approval_mode'] as String? ?? 'auto',
        pendingQuestion = (j['pending_question'] as Map?)?.cast<String, dynamic>(),
        totalTokens = (j['total_tokens'] as num?)?.toInt() ?? 0,
        lastPromptTokens = (j['last_prompt_tokens'] as num?)?.toInt() ?? 0;
}
