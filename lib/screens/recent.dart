import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'folder.dart';
import 'models.dart';
import 'session.dart';

/// The machine's landing screen: recent active sessions across all folders (the
/// fast path back into ongoing work), with a jump into the folder browser and a
/// one-tap home button back to instance selection.
class RecentSessionsScreen extends StatefulWidget {
  final DaemonClient client;
  final Instance instance;
  const RecentSessionsScreen({super.key, required this.client, required this.instance});
  @override
  State<RecentSessionsScreen> createState() => _RecentSessionsScreenState();
}

class _RecentSessionsScreenState extends State<RecentSessionsScreen> {
  late Future<List<SessionInfo>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.client.sessions(limit: 60);
  }

  void _reload() => setState(() => _future = widget.client.sessions(limit: 60));

  String _ago(int unixSec) {
    if (unixSec == 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(unixSec * 1000));
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  String _pill(String status) => switch (status) {
        'running' || 'waiting_for_input' => 'running',
        'failed' || 'error' => 'error',
        _ => 'idle',
      };

  String _folderName(String folder) =>
      folder.split('/').where((s) => s.isNotEmpty).lastOrNull ?? (folder.isEmpty ? '—' : folder);

  void _open(SessionInfo s) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SessionScreen(client: widget.client, sessionId: s.id, title: s.title, profile: s.profile),
    )).then((_) => _reload());
  }

  void _browse() {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => FolderScreen(client: widget.client, instance: widget.instance),
    )).then((_) => _reload());
  }

  Future<void> _rename(SessionInfo s) async {
    final title = await promptText(context,
        title: 'Rename session', initial: s.title, hint: 'New title', saveLabel: 'Rename');
    if (title == null) return;
    try {
      await widget.client.renameSession(s.id, title);
      _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(SessionInfo s) async {
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
      _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(
            title: widget.instance.label,
            subtitle: 'Recent sessions',
            onBack: () => Navigator.pop(context),
            actions: [
              IconBtn('folder', tooltip: 'Browse folders', onTap: _browse),
              IconBtn('cpu', tooltip: 'Models', onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => ModelsScreen(client: widget.client),
              ))),
              IconBtn('refresh', onTap: _reload),
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
                final list = snap.data ?? const [];
                if (list.isEmpty) {
                  return EmptyState(
                    icon: 'history',
                    title: 'No sessions yet',
                    body: 'Browse to a folder and start one.',
                    action: Btn('Browse folders', icon: 'folder', onTap: _browse),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _row(list[i]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(SessionInfo s) {
    return AppCard(
      onTap: () => _open(s),
      padding: const EdgeInsets.fromLTRB(13, 11, 6, 11),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.title.isEmpty ? '(untitled)' : s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: sans(13.5, height: 1.3, color: AppColors.fg1)),
            const SizedBox(height: 5),
            Row(children: [
              const AppIcon('folder', size: 11, color: AppColors.fg4),
              const SizedBox(width: 5),
              Flexible(child: Text(_folderName(s.folder), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5, color: AppColors.fg3))),
              if (_ago(s.lastActive).isNotEmpty) ...[
                Text('  ·  ${_ago(s.lastActive)}', style: mono(10.5, color: AppColors.fg4)),
              ],
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        StatusPill(status: _pill(s.status)),
        IconBtn('edit', size: 34, iconSize: 15, onTap: () => _rename(s)),
        IconBtn('trash', size: 34, iconSize: 16, onTap: () => _delete(s)),
      ]),
    );
  }
}
