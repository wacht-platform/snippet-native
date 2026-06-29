import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'files.dart';
import 'folder_browser.dart';
import 'models.dart';
import 'session.dart';

class SessionsScreen extends StatefulWidget {
  final DaemonClient client;
  final Instance instance;
  const SessionsScreen({super.key, required this.client, required this.instance});
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late Future<List<SessionInfo>> _future;
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _future = widget.client.sessions();
  }

  void _refresh() => setState(() { _future = widget.client.sessions(); });

  Future<void> _open(String id, String title, [String? profile]) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => SessionScreen(client: widget.client, sessionId: id, title: title, profile: profile)));
    _refresh();
  }

  Future<void> _newSession() async {
    final id = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => FolderBrowser(client: widget.client)));
    if (id != null && mounted) await _open(id, 'New session');
  }

  String _pillStatus(String s) => switch (s) {
        'running' => 'running',
        'waiting_for_input' => 'running',
        'failed' => 'error',
        _ => 'idle',
      };

  // Build a folder tree from session workspace paths; conversations are leaves.
  List<Widget> _tree(List<SessionInfo> sessions) {
    final root = _Node('', '');
    for (final s in sessions) {
      final segs = s.folder.split('/').where((x) => x.isNotEmpty).toList();
      var node = root;
      var acc = '';
      for (final seg in segs) {
        acc = '$acc/$seg';
        node = node.dirs.putIfAbsent(seg, () => _Node(seg, acc));
      }
      node.sessions.add(s);
    }
    final out = <Widget>[];
    _render(root, 0, out);
    return out;
  }

  int _count(_Node n) {
    var c = n.sessions.length;
    for (final d in n.dirs.values) {
      c += _count(d);
    }
    return c;
  }

  void _render(_Node n, int depth, List<Widget> out) {
    final dirs = n.dirs.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    for (var d in dirs) {
      var label = d.name;
      // collapse single-child chains (home/snippet/code) into one row
      while (d.dirs.length == 1 && d.sessions.isEmpty) {
        final only = d.dirs.values.first;
        label = '$label/${only.name}';
        d = only;
      }
      final expanded = !_collapsed.contains(d.path);
      out.add(_folderRow(label, d.path, depth, expanded, _count(d)));
      if (expanded) _render(d, depth + 1, out);
    }
    for (final s in n.sessions) {
      out.add(_sessionRow(s, depth));
    }
  }

  Widget _folderRow(String label, String path, int depth, bool expanded, int count) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.sm),
        onTap: () => setState(() {
          if (expanded) {
            _collapsed.add(path);
          } else {
            _collapsed.remove(path);
          }
        }),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12 + depth * 14.0, 9, 12, 9),
          child: Row(children: [
            AppIcon(expanded ? 'chevron-down' : 'chevron-right', size: 16, color: AppColors.fg4),
            const SizedBox(width: 4),
            const AppIcon('folder', size: 16, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(12.5, color: AppColors.fg1))),
            Text('$count', style: mono(11, color: AppColors.fg4)),
          ]),
        ),
      ),
    );
  }

  Widget _sessionRow(SessionInfo s, int depth) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.sm),
        onTap: () => _open(s.id, s.title, s.profile),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12 + (depth + 1) * 14.0, 9, 12, 9),
          child: Row(children: [
            const AppIcon('layers', size: 14, color: AppColors.fg4),
            const SizedBox(width: 8),
            Expanded(child: Text(s.title.isEmpty ? '(untitled)' : s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13.5, color: AppColors.fg1))),
            const SizedBox(width: 8),
            StatusPill(status: _pillStatus(s.status)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(
            title: widget.instance.label,
            subtitle: hostOf(widget.instance.url),
            onBack: () => Navigator.pop(context),
            actions: [
              IconBtn('refresh', onTap: _refresh),
              IconBtn('folder', tooltip: 'Browse files', onTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => FileExplorer(client: widget.client, title: widget.instance.label)));
              }),
              IconBtn('cpu', tooltip: 'Models', onTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => ModelsScreen(client: widget.client)));
              }),
            ],
          ),
          Expanded(
            child: FutureBuilder<List<SessionInfo>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)));
                }
                if (snap.hasError) {
                  return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center, style: sans(12.5, color: AppColors.fg3))));
                }
                final sessions = snap.data ?? const [];
                return RefreshIndicator(
                  color: AppColors.accent,
                  backgroundColor: AppColors.surface2,
                  onRefresh: () async => _refresh(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(6, 10, 10, 16),
                    children: [
                      if (sessions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: EmptyState(icon: 'terminal', title: 'No sessions yet', body: 'Open a folder to start a coding session on this machine.'),
                        ),
                      ..._tree(sessions),
                    ],
                  ),
                );
              },
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
            child: Btn('Open folder', icon: 'folder-open', full: true, onTap: _newSession),
          ),
        ]),
      ),
    );
  }
}

class _Node {
  final String name;
  final String path;
  final Map<String, _Node> dirs = {};
  final List<SessionInfo> sessions = [];
  _Node(this.name, this.path);
}
