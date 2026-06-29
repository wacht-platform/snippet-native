import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'files.dart';
import 'models.dart';
import 'session.dart';

/// One folder on a machine, with two tabs: its agent **Sessions** and the **Folder**
/// (file browser). Drilling into a subfolder pushes another FolderScreen. Sessions
/// is the default tab when the folder has any. Replaces the flat sessions list so a
/// device with many folders/sessions stays navigable.
class FolderScreen extends StatefulWidget {
  final DaemonClient client;
  final Instance instance;
  final String? path; // null = the machine's home dir (daemon /fs default)
  const FolderScreen({super.key, required this.client, required this.instance, this.path});
  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  FsListing? _fs;
  List<SessionInfo> _sessions = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Resolve the folder first, then fetch only THIS folder's sessions + the
      // device-wide counts map (for subfolder badges) — never the full list.
      final fs = await widget.client.fs(widget.path);
      final results = await Future.wait([
        widget.client.sessions(folder: fs.path),
        widget.client.sessionCounts(),
      ]);
      if (!mounted) return;
      final here = (results[0] as List<SessionInfo>)..sort((a, b) => b.lastActive.compareTo(a.lastActive));
      setState(() {
        _fs = fs;
        _sessions = here;
        _counts = results[1] as Map<String, int>;
        _loading = false;
      });
      // Sessions first when the folder has any, else the file browser.
      if (initial) {
        _tabs.index = here.isNotEmpty ? 0 : 1;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Map<String, int> _counts = const {};

  int _sessionsUnder(String dirPath) {
    final p = '$dirPath/';
    var n = 0;
    _counts.forEach((folder, c) {
      if (folder == dirPath || folder.startsWith(p)) n += c;
    });
    return n;
  }

  String _pill(String status) => switch (status) {
        'running' || 'waiting_for_input' => 'running',
        'failed' || 'error' => 'error',
        _ => 'idle',
      };

  void _openSession(SessionInfo s) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SessionScreen(client: widget.client, sessionId: s.id, title: s.title, profile: s.profile),
    )).then((_) => _load());
  }

  Future<void> _newSession() async {
    final folder = _fs?.path;
    if (folder == null) return;
    try {
      // Always start a fresh conversation — the folder's existing sessions stay
      // listed above and can be resumed by tapping them.
      final id = await widget.client.openSession(folder, newConversation: true);
      if (!mounted) return;
      final name = folder.split('/').where((s) => s.isNotEmpty).lastOrNull ?? folder;
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => SessionScreen(client: widget.client, sessionId: id, title: name, profile: null),
      )).then((_) => _load());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _renameSession(SessionInfo s) async {
    final title = await promptText(context,
        title: 'Rename session', initial: s.title, hint: 'New title', saveLabel: 'Rename');
    if (title == null) return;
    try {
      await widget.client.renameSession(s.id, title);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _deleteSession(SessionInfo s) async {
    final ok = await showAppSheet<bool>(context, title: 'Delete session?', child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.title.isEmpty ? '(untitled session)' : s.title, style: sans(13.5, height: 1.4, color: AppColors.fg1)),
        const SizedBox(height: 6),
        Text('This permanently removes the conversation. The folder and its files are untouched.', style: sans(12, height: 1.45, color: AppColors.fg3)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Btn('Cancel', variant: BtnVariant.secondary, onTap: () => Navigator.pop(context, false))),
          const SizedBox(width: 10),
          Expanded(child: Btn('Delete', variant: BtnVariant.danger, icon: 'trash', onTap: () => Navigator.pop(context, true))),
        ]),
      ],
    ));
    if (ok != true) return;
    try {
      await widget.client.deleteSession(s.id);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fs = _fs;
    final name = fs == null
        ? widget.instance.label
        : (fs.path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? fs.path);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(
            title: name,
            subtitle: fs?.path,
            onBack: () => Navigator.pop(context),
            actions: [
              IconBtn('home', tooltip: 'Instances', onTap: () => Navigator.popUntil(context, (r) => r.isFirst)),
              IconBtn('refresh', onTap: _load),
              IconBtn('cpu', tooltip: 'Models', onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => ModelsScreen(client: widget.client),
              ))),
            ],
          ),
          Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
            child: TabBar(
              controller: _tabs,
              labelColor: AppColors.fg1,
              unselectedLabelColor: AppColors.fg3,
              indicatorColor: AppColors.accent,
              dividerColor: Colors.transparent,
              labelStyle: sans(13, weight: FontWeight.w600),
              tabs: [
                Tab(text: _sessions.isEmpty ? 'Sessions' : 'Sessions (${_sessions.length})'),
                const Tab(text: 'Folder'),
              ],
            ),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center, style: sans(12.5, color: AppColors.fg3)))
          else if (_loading && fs == null)
            const Expanded(child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))))
          else
            Expanded(child: TabBarView(controller: _tabs, children: [_sessionsTab(), _folderTab()])),
        ]),
      ),
    );
  }

  Widget _sessionsTab() {
    return Column(children: [
      Expanded(
        child: _sessions.isEmpty
            ? EmptyState(icon: 'layers', title: 'No sessions here', body: 'Start an agent session in this folder.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                itemCount: _sessions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) => _sessionRow(_sessions[i]),
              ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(14, 8, 14, 12 + MediaQuery.of(context).padding.bottom),
        child: Btn('New session here', icon: 'plus', full: true, onTap: _fs == null ? null : _newSession),
      ),
    ]);
  }

  Widget _sessionRow(SessionInfo s) {
    return AppCard(
      onTap: () => _openSession(s),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Row(children: [
        const AppIcon('layers', size: 16, color: AppColors.fg3),
        const SizedBox(width: 10),
        Expanded(
          child: Text(s.title.isEmpty ? '(untitled)' : s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: sans(13, height: 1.3, color: AppColors.fg1)),
        ),
        const SizedBox(width: 8),
        StatusPill(status: _pill(s.status)),
        IconBtn('edit', size: 34, iconSize: 15, onTap: () => _renameSession(s)),
        IconBtn('trash', size: 34, iconSize: 16, onTap: () => _deleteSession(s)),
      ]),
    );
  }

  Widget _folderTab() {
    final fs = _fs;
    if (fs == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      children: [
        if (fs.parent != null)
          _row(icon: 'folder-open', name: '..', muted: true, onTap: () => _push(fs.parent!)),
        ...fs.entries.map((e) {
          if (e.isDir) {
            final n = _sessionsUnder(e.path);
            return _row(icon: 'folder', name: e.name, git: e.git, badge: n > 0 ? '$n' : null, chevron: true, onTap: () => _push(e.path));
          }
          return _row(icon: 'file', name: e.name, onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => FileViewer(client: widget.client, path: e.path, name: e.name),
          )));
        }),
      ],
    );
  }

  void _push(String path) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => FolderScreen(client: widget.client, instance: widget.instance, path: path),
    )).then((_) => _load());
  }

  Widget _row({required String icon, required String name, bool git = false, bool muted = false, bool chevron = false, String? badge, VoidCallback? onTap}) {
    final isFile = icon == 'file';
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            AppIcon(icon, size: 18, color: isFile ? AppColors.fg3 : AppColors.accent),
            const SizedBox(width: 11),
            Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(13, color: muted ? AppColors.fg3 : AppColors.fg1))),
            if (badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: AppColors.accentBg, borderRadius: BorderRadius.circular(99)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const AppIcon('layers', size: 10, color: AppColors.accent),
                  const SizedBox(width: 4),
                  Text(badge, style: mono(10.5, color: AppColors.accent)),
                ]),
              ),
              const SizedBox(width: 8),
            ],
            if (git) ...[
              const AppIcon('git-branch', size: 12, color: AppColors.ok),
              const SizedBox(width: 8),
            ],
            if (chevron) const AppIcon('chevron-right', size: 16, color: AppColors.fg4),
          ]),
        ),
      ),
    );
  }
}
