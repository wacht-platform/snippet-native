import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../command_palette.dart';
import '../models.dart';
import '../notifications.dart';
import '../panel.dart';
import '../platform.dart';
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
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final InstanceStore _store = InstanceStore();
  List<Instance> _instances = const [];
  Instance? _active;
  DaemonClient? _client;
  String? _sessionId;
  String _sessionTitle = '';
  String? _sessionProfile;
  bool _loading = true;
  // Session list lives here (not in the sidebar) so it survives drawer open/close
  // and is shared with the "recent sessions" placeholder.
  List<SessionInfo>? _sessions;
  bool _sessionsLoading = false;

  @override
  void initState() {
    super.initState();
    _loadInstances();
    // Tapping a session notification opens it in-place (consistent with the app),
    // not a separate full-screen route.
    if (kCanNotify) onNotifTap = _onNotif;
  }

  @override
  void dispose() {
    if (onNotifTap == _onNotif) onNotifTap = null;
    super.dispose();
  }

  void _onNotif(Map<String, dynamic> m) {
    if (!mounted) return;
    final url = '${m['url']}';
    final token = '${m['token']}';
    final sid = '${m['session'] ?? ''}';
    if (url.isEmpty || sid.isEmpty) return;
    Instance? inst;
    for (final i in _instances) {
      if (i.url == url) {
        inst = i;
        break;
      }
    }
    setState(() {
      _active = inst;
      _client = DaemonClient(url, token);
      _sessionId = sid;
      _sessionTitle = '${m['title'] ?? 'session'}';
      _sessionProfile = null;
      _sessions = null;
    });
    _loadSessions();
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
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final c = _client;
    if (c == null) {
      setState(() => _sessions = const []);
      return;
    }
    setState(() => _sessionsLoading = true);
    try {
      final s = await c.sessions(limit: 60);
      s.sort((a, b) => b.lastActive.compareTo(a.lastActive));
      if (mounted) setState(() { _sessions = s; _sessionsLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _sessionsLoading = false);
    }
  }

  Future<void> _newSessionFlow() async {
    final c = _client;
    if (c == null) return;
    final id = await presentScreen<String>(
      context,
      builder: (_, close) => FolderBrowser(client: c, newConversation: true),
    );
    if (id != null) {
      _openSession(id, 'New session', null);
      _loadSessions();
    }
  }

  void _selectInstance(Instance inst) {
    setState(() {
      _active = inst;
      _client = DaemonClient(inst.url, inst.token);
      _sessionId = null;
      _sessions = null;
    });
    _loadSessions();
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

  Widget _sidebar({VoidCallback? onAfterPick}) => _Sidebar(
        instances: _instances,
        active: _active,
        client: _client,
        selectedSessionId: _sessionId,
        sessions: _sessions,
        sessionsLoading: _sessionsLoading,
        onRefreshSessions: _loadSessions,
        onNewSession: () {
          _newSessionFlow();
          onAfterPick?.call();
        },
        onSelectInstance: _selectInstance,
        onOpenSession: (id, title, profile) {
          _openSession(id, title, profile);
          onAfterPick?.call();
        },
        onInstanceAdded: _onInstanceAdded,
        onRemoveInstance: _removeInstance,
        onSessionDeleted: _onSessionDeleted,
      );

  void _onSessionDeleted(String id) {
    if (_sessionId == id) {
      setState(() {
        _sessionId = null;
        _sessionTitle = '';
        _sessionProfile = null;
      });
    }
    _loadSessions();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppColors.canvas,
        body: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      // Narrow window → keep the native shell but collapse the sidebar to a drawer.
      if (c.maxWidth < kShellCompact) {
        // Wider drawer on phones; capped so it doesn't swallow the whole screen.
        final drawerW = (c.maxWidth * 0.86).clamp(280.0, 360.0);
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: AppColors.canvas,
          drawerEdgeDragWidth: 24,
          drawer: Drawer(
            width: drawerW,
            backgroundColor: AppColors.canvas,
            shape: const RoundedRectangleBorder(),
            child: SafeArea(child: _sidebar(onAfterPick: () => _scaffoldKey.currentState?.closeDrawer())),
          ),
          // Narrow: the toolbar's sidebar-toggle is at the far left under the
          // traffic lights, so inset the whole pane below them.
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: kMacOS ? kMacTitlebar : 0),
              child: _mainPane(onMenu: () => _scaffoldKey.currentState?.openDrawer()),
            ),
          ),
        );
      }
      // Wide: only the sidebar (top-left) sits under the traffic lights; the chat
      // toolbar fills the title-bar row at the top — no dead strip.
      return Scaffold(
        backgroundColor: AppColors.canvas,
        body: SafeArea(
          child: Row(children: [
            SizedBox(width: 300, child: _sidebar()),
            const VerticalDivider(width: 1, thickness: 1, color: AppColors.border),
            Expanded(child: _mainPane()),
          ]),
        ),
      );
    });
  }

  Widget _mainPane({VoidCallback? onMenu}) {
    final client = _client;
    if (client == null) {
      return _withMenu(onMenu, _welcome());
    }
    if (_sessionId == null) {
      return _withMenu(onMenu, _recentPlaceholder());
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
          onMenu: onMenu,
        ),
      );
    });
  }

  // No session selected → recent sessions + a New chat button (instead of a bare
  // "nothing selected" message).
  Widget _recentPlaceholder() {
    final sessions = (_sessions ?? const <SessionInfo>[]).take(8).toList();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          children: [
            Text('Recent sessions', style: sans(15, color: AppColors.fg1)),
            const SizedBox(height: 4),
            Text('Pick up where you left off, or start a new chat.', style: sans(12.5, height: 1.4, color: AppColors.fg3)),
            const SizedBox(height: 16),
            Btn('New chat', icon: 'edit', full: true, onTap: _newSessionFlow),
            const SizedBox(height: 12),
            if (_sessionsLoading && _sessions == null)
              const Center(child: Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))))
            else if (sessions.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text('No sessions yet.', style: sans(12.5, color: AppColors.fg4)))
            else
              ...sessions.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: AppCard(
                      onTap: () => _openSession(s.id, s.title, s.profile),
                      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s.title.isEmpty ? '(untitled)' : s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13, color: AppColors.fg1)),
                            const SizedBox(height: 2),
                            Text(s.folder.split('/').where((p) => p.isNotEmpty).lastOrNull ?? s.folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5, color: AppColors.fg4)),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        Text(_ago(s.lastActive), style: mono(10, color: AppColors.fg4)),
                      ]),
                    ),
                  )),
          ],
        ),
      ),
    );
  }

  String _ago(int unixSec) {
    if (unixSec == 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(unixSec * 1000));
    if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 30) return '${d.inDays}d';
    return '${(d.inDays / 30).floor()}mo';
  }

  // When collapsed, overlay a sidebar-toggle on the welcome/empty states.
  Widget _withMenu(VoidCallback? onMenu, Widget child) {
    if (onMenu == null) return child;
    return Stack(children: [
      child,
      Positioned(top: 6, left: 6, child: IconBtn('sidebar', tooltip: 'Sidebar', onTap: onMenu)),
    ]);
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
  final bool startOpen; // reveal the input immediately (no intermediate button)
  final VoidCallback? onCancel; // dismiss the whole field (vs collapsing to a button)
  const _AddInstanceField({required this.onAdded, this.dense = false, this.startOpen = false, this.onCancel});
  @override
  State<_AddInstanceField> createState() => _AddInstanceFieldState();
}

class _AddInstanceFieldState extends State<_AddInstanceField> {
  final _ctrl = TextEditingController();
  late bool _open = widget.startOpen;
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
      AppField(
        controller: _ctrl,
        mono: true,
        autofocus: true,
        hint: 'Paste connection string…',
        onSubmitted: (_) => _connect(),
        rightSlot: _busy
            ? const Padding(padding: EdgeInsets.only(left: 6), child: SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)))
            : IconBtn('arrow-right', size: 26, iconSize: 16, tooltip: 'Connect', onTap: _connect),
      ),
      const SizedBox(height: 6),
      Row(children: [
        if (_error != null) Expanded(child: Text(_error!, style: sans(11, color: AppColors.danger))) else const Spacer(),
        GestureDetector(
          onTap: () {
            _ctrl.clear();
            if (widget.onCancel != null) {
              widget.onCancel!(); // dismiss entirely (don't fall back to a button)
            } else {
              setState(() {
                _open = false;
                _error = null;
              });
            }
          },
          child: Text('Cancel', style: sans(11.5, color: AppColors.fg3)),
        ),
      ]),
    ]);
  }
}

class _Sidebar extends StatefulWidget {
  final List<Instance> instances;
  final Instance? active;
  final DaemonClient? client;
  final String? selectedSessionId;
  final List<SessionInfo>? sessions;
  final bool sessionsLoading;
  final VoidCallback onRefreshSessions;
  final VoidCallback onNewSession;
  final void Function(Instance) onSelectInstance;
  final void Function(String id, String title, String? profile) onOpenSession;
  final void Function(Instance) onInstanceAdded;
  final void Function(Instance) onRemoveInstance;
  final void Function(String id) onSessionDeleted;
  const _Sidebar({
    required this.instances,
    required this.active,
    required this.client,
    required this.selectedSessionId,
    required this.sessions,
    required this.sessionsLoading,
    required this.onRefreshSessions,
    required this.onNewSession,
    required this.onSelectInstance,
    required this.onOpenSession,
    required this.onInstanceAdded,
    required this.onRemoveInstance,
    required this.onSessionDeleted,
  });
  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  // The session list now lives in the shell (passed via widget.sessions); the
  // sidebar is presentational, so opening the drawer doesn't refetch.
  bool _adding = false; // inline add-instance field revealed

  List<SessionInfo>? get _sessions => widget.sessions;
  bool get _loading => widget.sessionsLoading;

  String _ago(int unixSec) {
    if (unixSec == 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(unixSec * 1000));
    if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 30) return '${d.inDays}d';
    return '${(d.inDays / 30).floor()}mo';
  }

  // Browse files (and run git) on any folder without opening a chat.
  void _openFiles() {
    final c = widget.client;
    if (c == null) return;
    presentScreen(context, builder: (_, close) => FileExplorer(client: c, title: widget.active?.label ?? 'Files', onClose: close));
  }

  void _openSearch() {
    showCommandPalette(
      context,
      sessions: _sessions ?? const [],
      onOpenChat: (s) => widget.onOpenSession(s.id, s.title, s.profile),
      commands: [
        PaletteCommand('edit', 'New chat', '', widget.onNewSession),
        PaletteCommand('folder', 'Open folder', '', widget.onNewSession),
        PaletteCommand('settings', 'Settings', '', _openSettings),
      ],
    );
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

  @override
  Widget build(BuildContext context) {
    final hasClient = widget.client != null;
    return Container(
      color: AppColors.canvas, // same surface as the chat canvas
      child: Column(children: [
        SizedBox(height: kMacOS ? kMacTitlebar + 6 : 6), // clear the window controls
        _navRow('edit', 'New chat', onTap: hasClient ? widget.onNewSession : null),
        _navRow('search', 'Search', onTap: hasClient ? _openSearch : null),
        _navRow('folder', 'Files', onTap: hasClient ? _openFiles : null),
        const SizedBox(height: 4),
        Expanded(
          child: !hasClient
              ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Add an instance to begin.', textAlign: TextAlign.center, style: sans(12.5, color: AppColors.fg4))))
              : _projects(),
        ),
        if (_adding)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: _AddInstanceField(
              dense: true,
              startOpen: true,
              onCancel: () => setState(() => _adding = false),
              onAdded: (inst) {
                setState(() => _adding = false);
                widget.onInstanceAdded(inst);
              },
            ),
          ),
        const Divider(height: 1, thickness: 1, color: AppColors.border),
        _footer(),
      ]),
    );
  }

  // The sidebar/drawer reads bigger on phones than on desktop.
  double get _navText => kMobile ? 15.5 : 13;
  double get _navIcon => kMobile ? 20 : 16;
  double get _navPadV => kMobile ? 12 : 8;
  double get _projText => kMobile ? 13.5 : 12;
  double get _rowTitle => kMobile ? 14.5 : 12.5;
  double get _rowTime => kMobile ? 11.5 : 10;
  double get _rowPadV => kMobile ? 11 : 6;

  Widget _navRow(String icon, String label, {VoidCallback? onTap, bool active = false}) {
    return Material(
      color: active ? AppColors.accentBg : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Padding(
            padding: EdgeInsets.fromLTRB(14, _navPadV, 14, _navPadV),
            child: Row(children: [
              AppIcon(icon, size: _navIcon, color: AppColors.fg2),
              const SizedBox(width: 11),
              Text(label, style: sans(_navText, color: AppColors.fg1)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _projects() {
    if (_loading && _sessions == null) {
      return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)));
    }
    final list = _sessions ?? const <SessionInfo>[];
    if (list.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('No chats yet.', style: sans(12.5, color: AppColors.fg4))));
    }
    // Group chats by folder (project); list is recency-sorted so each group is too.
    final order = <String>[];
    final groups = <String, List<SessionInfo>>{};
    for (final s in list) {
      (groups[s.folder] ??= () {
        order.add(s.folder);
        return <SessionInfo>[];
      }())
          .add(s);
    }
    // Sort projects by last activity (their most recent session) — newest first.
    order.sort((a, b) => groups[b]!.first.lastActive.compareTo(groups[a]!.first.lastActive));
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 4, 4),
          child: Row(children: [
            const Expanded(child: SectionLabel('Projects')),
            IconBtn('refresh', size: 26, iconSize: 13, onTap: _loading ? null : widget.onRefreshSessions),
          ]),
        ),
        for (final f in order) ...[
          _projectHeader(f),
          ...groups[f]!.map(_sessionRow),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _projectHeader(String folder) {
    final name = folder.split('/').where((p) => p.isNotEmpty).lastOrNull ?? (folder.isEmpty ? '—' : folder);
    // Show just the project name; reveal the full folder + machine on hover/long-press.
    final machine = widget.active?.label;
    final detail = machine == null || machine.isEmpty ? folder : '$folder\non $machine';
    return Tooltip(
      message: detail,
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 3),
        child: Row(children: [
          AppIcon('layers', size: kMobile ? 15 : 13, color: AppColors.fg3),
          const SizedBox(width: 8),
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(_projText, color: AppColors.fg2))),
        ]),
      ),
    );
  }

  Widget _sessionRow(SessionInfo s) {
    final selected = s.id == widget.selectedSessionId;
    final running = s.status == 'running' || s.status == 'waiting_for_input';
    return Material(
      color: selected ? AppColors.accentBg : Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.sm),
        onTap: () => widget.onOpenSession(s.id, s.title, s.profile),
        onLongPress: () => _sessionActions(s),
        onSecondaryTap: () => _sessionActions(s),
        child: Padding(
          padding: EdgeInsets.fromLTRB(kMobile ? 16 : 20, _rowPadV, 8, _rowPadV),
          child: Row(children: [
            if (running) ...[
              Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.fg1, shape: BoxShape.circle)),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(s.title.isEmpty ? '(untitled)' : s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(_rowTitle, color: selected ? AppColors.fg1 : AppColors.fg2))),
            const SizedBox(width: 6),
            Text(_ago(s.lastActive), style: mono(_rowTime, color: AppColors.fg4)),
          ]),
        ),
      ),
    );
  }

  // Long-press / right-click a session → rename or delete.
  void _sessionActions(SessionInfo s) {
    showAppSheet(context, title: s.title.isEmpty ? '(untitled)' : s.title, child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sessionActionTile('edit', 'Rename', onTap: () {
          Navigator.pop(context);
          _renameSession(s);
        }),
        _sessionActionTile('trash', 'Delete', danger: true, onTap: () {
          Navigator.pop(context);
          _confirmDeleteSession(s);
        }),
      ],
    ));
  }

  Widget _sessionActionTile(String icon, String label, {required VoidCallback onTap, bool danger = false}) {
    final color = danger ? AppColors.danger : AppColors.fg1;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 13),
          child: Row(children: [
            AppIcon(icon, size: 16, color: color),
            const SizedBox(width: 12),
            Text(label, style: sans(13.5, color: color)),
          ]),
        ),
      ),
    );
  }

  Future<void> _renameSession(SessionInfo s) async {
    final c = widget.client;
    if (c == null) return;
    final title = await promptText(context, title: 'Rename session', initial: s.title, hint: 'New title', saveLabel: 'Rename');
    if (title == null) return;
    try {
      await c.renameSession(s.id, title);
      widget.onRefreshSessions();
    } catch (e) {
      if (mounted) toast(context, '$e', danger: true);
    }
  }

  Future<void> _confirmDeleteSession(SessionInfo s) async {
    final c = widget.client;
    if (c == null) return;
    final ok = await showAppSheet<bool>(context, title: 'Delete session?', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.title.isEmpty ? '(untitled session)' : s.title, style: sans(13.5, color: AppColors.fg1)),
        const SizedBox(height: 6),
        Text('Permanently removes the conversation. The folder and its files are untouched.', style: sans(12, height: 1.45, color: AppColors.fg3)),
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
      await c.deleteSession(s.id);
      widget.onSessionDeleted(s.id);
      widget.onRefreshSessions();
    } catch (e) {
      if (mounted) toast(context, '$e', danger: true);
    }
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 8),
      child: Row(children: [
        Expanded(child: _instanceProfile(widget.active)),
        if (widget.client != null) IconBtn('settings', size: 32, iconSize: 16, tooltip: 'Settings', onTap: _openSettings),
      ]),
    );
  }

  Widget _instanceProfile(Instance? active) {
    return PopupMenuButton<String>(
      color: AppColors.surface2,
      offset: const Offset(0, -8),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.surface3, borderRadius: BorderRadius.circular(R.sm)),
            child: const AppIcon('cpu', size: 14, color: AppColors.fg2),
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(active?.label ?? 'No instance', maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(12.5, color: AppColors.fg1))),
          const AppIcon('chevron-down', size: 14, color: AppColors.fg3),
        ]),
      ),
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
  bool _notif = false;
  bool _notifBusy = false;

  @override
  void initState() {
    super.initState();
    notificationsEnabled().then((v) {
      if (mounted) setState(() => _notif = v);
    });
  }

  Future<void> _toggleNotif(bool v) async {
    setState(() => _notifBusy = true);
    final err = await setNotificationsEnabled(v);
    if (!mounted) return;
    setState(() {
      _notifBusy = false;
      _notif = err == null ? v : _notif;
    });
    if (err != null) toast(context, err);
  }

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
                    () => presentScreen(context, builder: (_, close) => ModelsScreen(client: widget.client, onClose: close))),
                if (kCanNotify) ...[
                  const SizedBox(height: 6),
                  _notifTile(),
                ],
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

  Widget _notifTile() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(R.md)),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: AppColors.surface3, borderRadius: BorderRadius.circular(R.sm)),
          child: const AppIcon('zap', size: 15, color: AppColors.fg2),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Notifications', style: sans(13, color: AppColors.fg1)),
            const SizedBox(height: 1),
            Text('Alert when a session needs input or finishes', style: sans(11, color: AppColors.fg4)),
          ]),
        ),
        _notifBusy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))
            : Transform.scale(
                scale: 0.78,
                child: Switch(
                  value: _notif,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeThumbColor: AppColors.accentFg,
                  activeTrackColor: AppColors.accent,
                  onChanged: _toggleNotif,
                ),
              ),
      ]),
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
