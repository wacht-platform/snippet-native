import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'folder_browser.dart';
import 'instances.dart';
import 'session.dart';

/// Mobile landing: the Instances screen only when nothing is connected yet,
/// otherwise the aggregated Sessions screen (with a button to manage machines).
class MobileHome extends StatefulWidget {
  const MobileHome({super.key});
  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  bool? _hasInstances;

  @override
  void initState() {
    super.initState();
    InstanceStore().load().then((i) {
      if (mounted) setState(() => _hasInstances = i.isNotEmpty);
    });
  }

  @override
  Widget build(BuildContext context) {
    final has = _hasInstances;
    if (has == null) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))),
      );
    }
    return has ? const AllSessionsScreen() : const InstancesScreen();
  }
}

/// Sessions across every connected machine, grouped by machine. A top button
/// jumps to the Instances screen to add/manage/switch machines.
class AllSessionsScreen extends StatefulWidget {
  const AllSessionsScreen({super.key});
  @override
  State<AllSessionsScreen> createState() => _AllSessionsScreenState();
}

class _AllSessionsScreenState extends State<AllSessionsScreen> {
  final _store = InstanceStore();
  List<Instance> _instances = const [];
  final Map<String, DaemonClient> _clients = {};
  final Map<String, List<SessionInfo>> _byUrl = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final insts = await _store.load();
    _clients
      ..clear()
      ..addEntries(insts.map((i) => MapEntry(i.url, DaemonClient(i.url, i.token))));
    await Future.wait(insts.map((i) async {
      try {
        final s = await _clients[i.url]!.sessions(limit: 60);
        s.sort((a, b) => b.lastActive.compareTo(a.lastActive));
        _byUrl[i.url] = s;
      } catch (_) {
        _byUrl[i.url] = const [];
      }
    }));
    if (mounted) {
      setState(() {
        _instances = insts;
        _loading = false;
      });
    }
  }

  Future<void> _openInstances() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const InstancesScreen()));
    if (mounted) _load();
  }

  void _open(Instance inst, SessionInfo s) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SessionScreen(client: _clients[inst.url]!, sessionId: s.id, title: s.title, profile: s.profile),
    )).then((_) => _load());
  }

  Future<void> _newSession(Instance inst) async {
    final id = await Navigator.push<String>(context, MaterialPageRoute(
      builder: (_) => FolderBrowser(client: _clients[inst.url]!, newConversation: true),
    ));
    if (id == null || !mounted) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SessionScreen(client: _clients[inst.url]!, sessionId: id, title: 'New session'),
    )).then((_) => _load());
  }

  String _ago(int unixSec) {
    if (unixSec == 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(unixSec * 1000));
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 30) return '${d.inDays}d';
    return '${(d.inDays / 30).floor()}mo';
  }

  String _folderName(String folder) => folder.split('/').where((p) => p.isNotEmpty).lastOrNull ?? (folder.isEmpty ? '—' : folder);

  @override
  Widget build(BuildContext context) {
    // One unified, recency-sorted list across every machine.
    final combined = <(Instance, SessionInfo)>[];
    for (final inst in _instances) {
      for (final s in (_byUrl[inst.url] ?? const <SessionInfo>[])) {
        combined.add((inst, s));
      }
    }
    combined.sort((a, b) => b.$2.lastActive.compareTo(a.$2.lastActive));
    return Scaffold(
      floatingActionButton: (_loading || _instances.isEmpty)
          ? null
          : FloatingActionButton(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.accentFg,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.card)),
              onPressed: _newSessionPicker,
              child: const AppIcon('plus', size: 22, color: AppColors.accentFg),
            ),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: 'Sessions', actions: [
            IconBtn('cpu', tooltip: 'Machines', onTap: _openInstances),
            IconBtn('refresh', onTap: _loading ? null : _load),
          ]),
          Expanded(
            child: _loading
                ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)))
                : RefreshIndicator(
                    color: AppColors.accent,
                    backgroundColor: AppColors.surface2,
                    onRefresh: _load,
                    child: _instances.isEmpty
                        ? ListView(children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 80),
                              child: EmptyState(icon: 'cpu', title: 'No machines', body: 'Connect a machine running snippet serve.', action: Btn('Add machine', icon: 'plus', onTap: _openInstances)),
                            ),
                          ])
                        : combined.isEmpty
                            ? ListView(children: const [
                                Padding(
                                  padding: EdgeInsets.only(top: 80),
                                  child: EmptyState(icon: 'layers', title: 'No sessions yet', body: 'Tap + to start one.'),
                                ),
                              ])
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(6, 4, 6, 96),
                                itemCount: combined.length,
                                separatorBuilder: (_, __) => Container(height: 1, margin: const EdgeInsets.only(left: 14), color: AppColors.border),
                                itemBuilder: (_, i) => _row(combined[i].$1, combined[i].$2),
                              ),
                  ),
          ),
        ]),
      ),
    );
  }

  Future<void> _newSessionPicker() async {
    if (_instances.isEmpty) return;
    if (_instances.length == 1) {
      _newSession(_instances.first);
      return;
    }
    final inst = await showAppSheet<Instance>(context, title: 'New session on…', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final i in _instances)
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(R.sm),
            child: InkWell(
              borderRadius: BorderRadius.circular(R.sm),
              onTap: () => Navigator.pop(context, i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(children: [
                  const AppIcon('cpu', size: 16, color: AppColors.fg3),
                  const SizedBox(width: 10),
                  Expanded(child: Text(i.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13.5, color: AppColors.fg1))),
                  const AppIcon('chevron-right', size: 14, color: AppColors.fg4),
                ]),
              ),
            ),
          ),
      ],
    ));
    if (inst != null) _newSession(inst);
  }

  Widget _row(Instance inst, SessionInfo s) {
    final running = s.status == 'running' || s.status == 'waiting_for_input';
    final failed = s.status == 'failed' || s.status == 'error';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _open(inst, s),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(children: [
            if (running || failed) ...[
              Container(width: 6, height: 6, decoration: BoxDecoration(color: failed ? AppColors.danger : AppColors.accent, shape: BoxShape.circle)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.title.isEmpty ? '(untitled)' : s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13.5, height: 1.25, color: AppColors.fg1)),
                const SizedBox(height: 3),
                Row(children: [
                  Expanded(child: Text('${inst.label}  ·  ${_folderName(s.folder)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5, color: AppColors.fg3))),
                  if (_ago(s.lastActive).isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(_ago(s.lastActive), style: mono(10.5, color: AppColors.fg4)),
                  ],
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            const AppIcon('chevron-right', size: 15, color: AppColors.fg4),
          ]),
        ),
      ),
    );
  }
}
