import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
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

  @override
  void initState() {
    super.initState();
    _future = widget.client.sessions();
  }

  void _refresh() => setState(() => _future = widget.client.sessions());

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

  Widget _sessionCard(SessionInfo s) {
    return AppCard(
      onTap: () => _open(s.id, s.title, s.profile),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(s.title.isEmpty ? '(untitled)' : s.title, style: sans(14, weight: FontWeight.w500, height: 1.35, color: AppColors.fg1))),
        const SizedBox(width: 10),
        StatusPill(status: _pillStatus(s.status)),
      ]),
    );
  }

  // Group conversations by their workspace folder, with a folder header each.
  List<Widget> _grouped(List<SessionInfo> sessions) {
    final groups = <String, List<SessionInfo>>{};
    for (final s in sessions) {
      (groups[s.folder] ??= []).add(s);
    }
    final out = <Widget>[];
    groups.forEach((folder, items) {
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
        child: Row(children: [
          const AppIcon('folder', size: 13, color: AppColors.fg4),
          const SizedBox(width: 7),
          Expanded(child: Text(folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11.5, color: AppColors.fg3))),
        ]),
      ));
      for (final s in items) {
        out.add(Padding(padding: const EdgeInsets.only(bottom: 10), child: _sessionCard(s)));
      }
      out.add(const SizedBox(height: 6));
    });
    return out;
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
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    children: [
                      if (sessions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: EmptyState(icon: 'terminal', title: 'No sessions yet', body: 'Open a folder to start a coding session on this machine.'),
                        ),
                      ..._grouped(sessions),
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
