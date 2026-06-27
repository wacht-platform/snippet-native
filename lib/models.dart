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

/// A configured model profile (from GET /config). Keys are never sent back — only
/// [hasKey] tells whether one is set.
class ModelProfile {
  final String name;
  final String provider;
  final String baseUrl;
  final String model;
  final bool hasKey;
  final bool active;
  final int contextWindow;

  ModelProfile.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String? ?? '',
        provider = j['provider'] as String? ?? '',
        baseUrl = j['base_url'] as String? ?? '',
        model = j['model'] as String? ?? '',
        hasKey = j['has_key'] == true,
        active = j['active'] == true,
        contextWindow = (j['context_window'] as num?)?.toInt() ?? 0;
}

class ServerConfig {
  final List<ModelProfile> profiles;
  final String? active;
  final bool manualApproval;
  final String hostname;

  ServerConfig.fromJson(Map<String, dynamic> j)
      : profiles = ((j['profiles'] as List?) ?? const [])
            .map((e) => ModelProfile.fromJson(e as Map<String, dynamic>))
            .toList(),
        active = j['active'] as String?,
        manualApproval = j['manual_approval'] == true,
        hostname = j['hostname'] as String? ?? '';
}

class SessionInfo {
  final String id;
  final String folder;
  final String conversation;
  final String title;
  final String status;
  final int lastActive;
  final bool running;
  final String? profile;

  SessionInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        folder = j['folder'] as String? ?? '',
        conversation = j['conversation'] as String? ?? '',
        title = j['title'] as String? ?? '',
        status = j['status'] as String? ?? '',
        lastActive = (j['last_active'] as num?)?.toInt() ?? 0,
        running = j['running'] == true,
        profile = j['profile'] as String?;
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

class FileContent {
  final String path;
  final String content;
  final int size;
  final bool truncated;
  final bool binary;

  FileContent.fromJson(Map<String, dynamic> j)
      : path = j['path'] as String? ?? '',
        content = j['content'] as String? ?? '',
        size = (j['size'] as num?)?.toInt() ?? 0,
        truncated = j['truncated'] == true,
        binary = j['binary'] == true;
}

class RateWindow {
  final double usedPercent;
  final int windowMinutes;
  final int resetsAt;
  RateWindow.fromJson(Map<String, dynamic> j)
      : usedPercent = (j['used_percent'] as num?)?.toDouble() ?? 0,
        windowMinutes = (j['window_minutes'] as num?)?.toInt() ?? 0,
        resetsAt = (j['resets_at'] as num?)?.toInt() ?? 0;
  double get leftPercent => (100 - usedPercent).clamp(0, 100).toDouble();
}

class Checkpoint {
  final String id;
  final String label;
  final String createdAt;
  Checkpoint.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        label = j['label'] as String? ?? '',
        createdAt = j['created_at'] as String? ?? '';
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
  final int promptTokens;
  final int completionTokens;
  final int cacheReadTokens;
  final int lastPromptTokens;
  final int contextWindow;
  final RateWindow? ratePrimary;
  final RateWindow? rateSecondary;
  final List<Checkpoint> checkpoints;

  HarnessState({
    required this.status,
    required this.workspace,
    required this.userRequest,
    required this.events,
    required this.finalText,
    required this.approvalMode,
    required this.pendingQuestion,
    required this.totalTokens,
    required this.promptTokens,
    required this.completionTokens,
    required this.cacheReadTokens,
    required this.lastPromptTokens,
    required this.contextWindow,
    required this.ratePrimary,
    required this.rateSecondary,
    required this.checkpoints,
  });

  factory HarnessState.fromJson(Map<String, dynamic> j) {
    final rl = j['rate_limit'] as Map<String, dynamic>?;
    RateWindow? win(String k) {
      final m = rl?[k];
      return m is Map ? RateWindow.fromJson(m.cast<String, dynamic>()) : null;
    }

    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return HarnessState(
      status: j['status'] as String? ?? 'idle',
      workspace: j['workspace'] as String? ?? '',
      userRequest: j['user_request'] as String? ?? '',
      events: ((j['events'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList(),
      finalText: j['final_text'] as String?,
      approvalMode: j['approval_mode'] as String? ?? 'auto',
      pendingQuestion: (j['pending_question'] as Map?)?.cast<String, dynamic>(),
      totalTokens: n('total_tokens'),
      promptTokens: n('prompt_tokens'),
      completionTokens: n('completion_tokens'),
      cacheReadTokens: n('cache_read_tokens'),
      lastPromptTokens: n('last_prompt_tokens'),
      contextWindow: n('context_window'),
      ratePrimary: win('primary'),
      rateSecondary: win('secondary'),
      checkpoints: ((j['checkpoints'] as List?) ?? const [])
          .map((e) => Checkpoint.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  /// Merge a delta frame: scalars come from `d`; events are the existing log
  /// plus the appended `new_events`.
  HarnessState applyDelta(Map<String, dynamic> d) {
    final base = HarnessState.fromJson(d); // scalars; events empty (delta omits them)
    final added = ((d['new_events'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    return HarnessState(
      status: base.status,
      workspace: base.workspace,
      userRequest: base.userRequest,
      events: [...events, ...added],
      finalText: base.finalText,
      approvalMode: base.approvalMode,
      pendingQuestion: base.pendingQuestion,
      totalTokens: base.totalTokens,
      promptTokens: base.promptTokens,
      completionTokens: base.completionTokens,
      cacheReadTokens: base.cacheReadTokens,
      lastPromptTokens: base.lastPromptTokens,
      contextWindow: base.contextWindow,
      ratePrimary: base.ratePrimary,
      rateSecondary: base.rateSecondary,
      checkpoints: base.checkpoints,
    );
  }
}

/// Human label for a rate-limit window length (mirrors the TUI).
String rateWindowLabel(int minutes) {
  bool near(int t) => (minutes - t).abs() <= (t * 0.05).round();
  if (near(300)) return '5h';
  if (near(1440)) return 'daily';
  if (near(10080)) return 'wk';
  if (near(43200)) return 'mo';
  if (minutes >= 60) return '${minutes ~/ 60}h';
  return 'limit';
}

/// Compact SI token formatting (mirrors the TUI's fmt_si: 91M / 425k / 512).
String fmtSi(int v) {
  if (v >= 1000000) {
    return '${(v / 1000000).toStringAsFixed(v >= 10000000 ? 0 : 1)}M';
  }
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 1)}k';
  return '$v';
}
