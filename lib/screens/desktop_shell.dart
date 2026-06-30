import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../panel.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'files.dart';
import 'folder_browser.dart';
import 'models.dart';
import 'session.dart';

/// Desktop two-pane shell: a persistent left sidebar (instances + sessions) and
/// a main pane showing the selected session. Tools (git/files/editor/models)
/// open as floating panels/drawers from within the session, or the sidebar.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final InstanceStore _store = InstanceStore();
  List<Instance> _instances = const [];
  Instance? _active;
  DaemonClient? _client;
  String? _sessionId;
  String _sessionTitle = '';
  String? _sessionProfile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadInstances();
  }

  Future<void> _loadInstances() async {
    final items = await _store.load();
    if (!mounted) return;
    setState(() {
      _instances = items;
      _active ??= items.isNotEmpty ? items.first : null;
      _client = _active != null ? DaemonClient(_active!.url, _active!.token) : null;
      _loading = false;
    });
  }

  void _selectInstance(Instance inst) {
    setState(() {
      _active = inst;
      _client = DaemonClient(inst.url, inst.token);
      _sessionId = null;
    });
  }

  void _openSession(String id, String title, String? profile) {
    setState(() {
      _sessionId = id;
      _sessionTitle = title;
      _sessionProfile = profile;
    });
  }

  Future<void> _onInstanceAdded(Instance inst) async {
    final items = [..._instances]..removeWhere((e) => e.url == inst.url);
    items.add(inst);
    await _store.save(items);
    if (!mounted) return;
    setState(() => _instances = items);
    _selectInstance(inst);
  }

  Future<void> _removeInstance(Instance inst) async {
    final items = [..._instances]..removeWhere((e) => e.url == inst.url);
    await _store.save(items);
    if (!mounted) return;
    setState(() {
      _instances = items;
      if (_active?.url == inst.url) {
        _active = items.isNotEmpty ? items.first : null;
        _client = _active != null ? DaemonClient(_active!.url, _active!.token) : null;
        _sessionId = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: _loading
            ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)))
            : Row(children: [
                SizedBox(
                  width: 300,
                  child: _Sidebar(
                    instances: _instances,
                    active: _active,
                    client: _client,
                    selectedSessionId: _sessionId,
                    onSelectInstance: _selectInstance,
                    onOpenSession: _openSession,
                    onInstanceAdded: _onInstanceAdded,
                    onRemoveInstance: _removeInstance,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1, color: AppColors.border),
                Expanded(child: _mainPane()),
              ]),
      ),
    );
  }

  Widget _mainPane() {
    final client = _client;
    if (client == null) {
      return _welcome();
    }
    if (_sessionId == null) {
      return const Center(child: EmptyState(icon: 'layers', title: 'No session selected', body: 'Pick a session on the left, or start a new one.'));
    }
    // Pane-scoped MediaQuery so window-width sizing (chat bubbles) fits the pane.
    return LayoutBuilder(builder: (ctx, c) {
      final mq = MediaQuery.of(ctx);
      return MediaQuery(
        data: mq.copyWith(size: Size(c.maxWidth, c.maxHeight)),
        child: SessionScreen(
          key: ValueKey('${_active!.url}|$_sessionId'),
          client: client,
          sessionId: _sessionId!,
          title: _sessionTitle,
          profile: _sessionProfile,
          embedded: true,
        ),
      );
    });
  }

  Widget _welcome() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(R.card), border: Border.all(color: AppColors.border)),
              child: const AppIcon('cpu', size: 24, color: AppColors.fg3),
            ),
          ),
          const SizedBox(height: 16),
          Text('No instance connected', textAlign: TextAlign.center, style: sans(15, color: AppColors.fg1)),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(style: sans(12.5, height: 1.5, color: AppColors.fg3), children: [
              const TextSpan(text: 'Run '),
              TextSpan(text: 'snippet serve', style: mono(12, color: AppColors.fg2)),
              const TextSpan(text: ' on a machine, then paste the connection string it prints.'),
            ]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          _AddInstanceField(onAdded: _onInstanceAdded),
        ]),
      ),
    );
  }
}

/// Inline "add connection": a button that morphs into a URL/token field and
/// connects on submit (replaces the full-screen add flow on desktop).
class _AddInstanceField extends StatefulWidget {
  final void Function(Instance) onAdded;
  final bool dense;
  const _AddInstanceField({required this.onAdded, this.dense = false});
  @override
  State<_AddInstanceField> createState() => _AddInstanceFieldState();
}

class _AddInstanceFieldState extends State<_AddInstanceField> {
  final _ctrl = TextEditingController();
  bool _open = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  (String, String)? _parse(String raw) {
    raw = raw.trim();
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.scheme.startsWith('http') && (uri.queryParameters['token'] ?? '').isNotEmpty) {
      final token = uri.queryParameters['token']!;
      final port = uri.hasPort ? ':${uri.port}' : '';
      return ('${uri.scheme}://${uri.host}$port', token);
    }
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['url'] is String && m['token'] is String) return (m['url'] as String, m['token'] as String);
    } catch (_) {}
    return null;
  }

  Future<void> _connect() async {
    if (_busy) return;
    final parsed = _parse(_ctrl.text);
    if (parsed == null) {
      setState(() => _error = 'Not a valid connection string.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final (url, token) = parsed;
      final cfg = await DaemonClient(url, token).getConfig();
      final name = cfg.hostname.isNotEmpty ? cfg.hostname : hostOf(url);
      widget.onAdded(Instance(name: name, url: url, token: token));
      if (mounted) {
        setState(() {
          _busy = false;
          _open = false;
          _ctrl.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not connect.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return Btn('Add instance', icon: 'plus', small: widget.dense, full: true, onTap: () => setState(() => _open = true));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: AppField(controller: _ctrl, mono: true, autofocus: true, hint: 'https://host/?token=…', onSubmitted: (_) => _connect())),
        const SizedBox(width: 8),
        Btn(_busy ? '…' : 'Connect', small: true, disabled: _busy, onTap: _connect),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: sans(11.5, color: AppColors.danger))),
    ]);
  }
}

class _Sidebar extends StatefulWidget {
  final List<Instance> instances;
  final Instance? active;
  final DaemonClient? client;
  final String? selectedSessionId;
  final void Function(Instance) onSelectInstance;
  final void Function(String id, String title, String? profile) onOpenSession;
  final void Function(Instance) onInstanceAdded;
  final void Function(Instance) onRemoveInstance;
  const _Sidebar({
    required this.instances,
    required this.active,
    required this.client,
    required this.selectedSessionId,
    required this.onSelectInstance,
    required this.onOpenSession,
    required this.onInstanceAdded,
    required this.onRemoveInstance,
  });
  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  List<SessionInfo>? _sessions;
  bool _loading = false;
  bool _adding = false; // inline add-instance field revealed
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_Sidebar old) {
    super.didUpdateWidget(old);
    if (old.client?.baseUrl != widget.client?.baseUrl) _load();
  }

  Future<void> _load() async {
    final c = widget.client;
    if (c == null) {
      setState(() => _sessions = const []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await c.sessions(limit: 60);
      s.sort((a, b) => b.lastActive.compareTo(a.lastActive));
      if (mounted) {
        setState(() {
          _sessions = s;
          _loading = false;
        });
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

  Future<void> _newSession() async {
    final c = widget.client;
    if (c == null) return;
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => FolderBrowser(client: c, newConversation: true)),
    );
    if (id != null) {
      widget.onOpenSession(id, 'New session', null);
      _load();
    }
  }

  void _openFiles() {
    final c = widget.client;
    if (c == null) return;
    presentScreen(context, builder: (_, close) => FileExplorer(client: c, onClose: close));
  }

  void _openSettings() {
    final c = widget.client;
    if (c == null) return;
    presentScreen(context, builder: (_, close) => _SettingsPanel(
      client: c,
      instances: widget.instances,
      active: widget.active,
      onRemove: widget.onRemoveInstance,
      onClose: close,
    ));
  }

  String _pill(String s) => switch (s) {
        'running' || 'waiting_for_input' => 'running',
        'failed' || 'error' => 'error',
        _ => 'idle',
      };

  @override
  Widget build(BuildContext context) {
    final hasClient = widget.client != null;
    return Container(
      color: AppColors.surface1, // subtle panel shade distinct from the main pane
      child: Column(children: [
        Row(children: [
          Expanded(child: _instanceHeader()),
          if (hasClient)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconBtn('settings', size: 34, iconSize: 17, tooltip: 'Settings', onTap: _openSettings),
            ),
        ]),
        const Divider(height: 1, thickness: 1, color: AppColors.border),
        if (_adding)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: _AddInstanceField(dense: true, onAdded: (inst) {
              setState(() => _adding = false);
              widget.onInstanceAdded(inst);
            }),
          ),
        // No instance → no sessions; just a hint (the main pane shows the welcome).
        if (!hasClient)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text('Add an instance to begin.', textAlign: TextAlign.center, style: sans(12.5, color: AppColors.fg4)),
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            child: Row(children: [
              Expanded(child: Text('SESSIONS', style: sans(11, color: AppColors.fg3, spacing: 0.4))),
              IconBtn('refresh', size: 30, iconSize: 15, onTap: _loading ? null : _load),
            ]),
          ),
          Expanded(child: _sessionList()),
          const Divider(height: 1, thickness: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(children: [
              Btn('New session', icon: 'plus', full: true, small: true, onTap: _newSession),
              const SizedBox(height: 6),
              Btn('Files', icon: 'folder', variant: BtnVariant.secondary, full: true, small: true, onTap: _openFiles),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _instanceHeader() {
    final active = widget.active;
    return PopupMenuButton<String>(
      color: AppColors.surface2,
      offset: const Offset(0, 44),
      elevation: 8,
      constraints: const BoxConstraints(minWidth: 224, maxWidth: 280),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: const BorderSide(color: AppColors.border2)),
      onSelected: (v) {
        if (v == '__add') {
          setState(() => _adding = true);
        } else {
          final inst = widget.instances.firstWhere((i) => i.url == v, orElse: () => widget.instances.first);
          widget.onSelectInstance(inst);
        }
      },
      itemBuilder: (_) => [
        ...widget.instances.map((i) => PopupMenuItem(
              value: i.url,
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                AppIcon(i.url == active?.url ? 'check' : 'cpu', size: 14, color: i.url == active?.url ? AppColors.accent : AppColors.fg3),
                const SizedBox(width: 9),
                Expanded(child: Text(i.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(12.5, color: AppColors.fg1))),
              ]),
            )),
        PopupMenuItem(
          value: '__add',
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            const AppIcon('plus', size: 14, color: AppColors.accent),
            const SizedBox(width: 9),
            Text('Add instance', style: sans(12.5, color: AppColors.accent)),
          ]),
        ),
      ],
      child: Container(
        height: 48,
        padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
        child: Row(children: [
          const AppIcon('cpu', size: 16, color: AppColors.accent),
          const SizedBox(width: 9),
          Expanded(child: Text(active?.label ?? 'No instance', maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13.5, color: AppColors.fg1))),
          const AppIcon('chevron-down', size: 15, color: AppColors.fg3),
        ]),
      ),
    );
  }

  Widget _sessionList() {
    if (_loading && _sessions == null) {
      return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)));
    }
    if (_error != null) {
      return Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: sans(12, color: AppColors.fg3)));
    }
    final list = _sessions ?? const [];
    if (list.isEmpty) {
      return const EmptyState(icon: 'layers', title: 'No sessions', body: 'Start a new one below.');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (_, i) {
        final s = list[i];
        final selected = s.id == widget.selectedSessionId;
        return Material(
          color: selected ? AppColors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(R.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(R.sm),
            onTap: () => widget.onOpenSession(s.id, s.title, s.profile),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.title.isEmpty ? '(untitled)' : s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(12.5, color: selected ? AppColors.fg1 : AppColors.fg1)),
                    const SizedBox(height: 2),
                    Text(s.folder.split('/').where((p) => p.isNotEmpty).lastOrNull ?? s.folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5, color: AppColors.fg4)),
                  ]),
                ),
                const SizedBox(width: 6),
                StatusPill(status: _pill(s.status)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Desktop settings drawer: manage saved instances (remove) + Models.
class _SettingsPanel extends StatefulWidget {
  final DaemonClient client;
  final List<Instance> instances;
  final Instance? active;
  final void Function(Instance) onRemove;
  final VoidCallback onClose;
  const _SettingsPanel({
    required this.client,
    required this.instances,
    required this.active,
    required this.onRemove,
    required this.onClose,
  });
  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  late final List<Instance> _instances = [...widget.instances];

  Future<void> _confirmRemove(Instance inst) async {
    final ok = await showAppSheet<bool>(context, title: 'Remove instance?', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(inst.label, style: sans(13.5, color: AppColors.fg1)),
        const SizedBox(height: 6),
        Text('Removes the saved connection from this app. The machine and its sessions are untouched.', style: sans(12, height: 1.45, color: AppColors.fg3)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Btn('Cancel', variant: BtnVariant.secondary, onTap: () => Navigator.pop(context, false))),
          const SizedBox(width: 10),
          Expanded(child: Btn('Remove', variant: BtnVariant.danger, icon: 'trash', onTap: () => Navigator.pop(context, true))),
        ]),
      ],
    ));
    if (ok != true) return;
    widget.onRemove(inst);
    setState(() => _instances.removeWhere((e) => e.url == inst.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: 'Settings', onBack: widget.onClose),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              children: [
                const SectionLabel('Instances'),
                const SizedBox(height: 6),
                ..._instances.map(_instanceRow),
                const SizedBox(height: 16),
                const SectionLabel('Configuration'),
                const SizedBox(height: 6),
                _tile('cpu', 'Models', 'Providers & active model',
                    () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ModelsScreen(client: widget.client)))),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _instanceRow(Instance i) {
    final isActive = i.url == widget.active?.url;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
        decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(R.md)),
        child: Row(children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: isActive ? AppColors.accent : AppColors.fg4, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13, color: AppColors.fg1)),
              const SizedBox(height: 1),
              Text(hostOf(i.url), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5, color: AppColors.fg4)),
            ]),
          ),
          IconBtn('trash', size: 32, iconSize: 16, tooltip: 'Remove', onTap: () => _confirmRemove(i)),
        ]),
      ),
    );
  }

  Widget _tile(String icon, String label, String sub, VoidCallback onTap) {
    return Material(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(R.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.surface3, borderRadius: BorderRadius.circular(R.sm)),
              child: AppIcon(icon, size: 15, color: AppColors.fg2),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: sans(13, color: AppColors.fg1)),
                const SizedBox(height: 1),
                Text(sub, style: sans(11, color: AppColors.fg4)),
              ]),
            ),
            const AppIcon('chevron-right', size: 15, color: AppColors.fg4),
          ]),
        ),
      ),
    );
  }
}
