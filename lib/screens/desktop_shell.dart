import 'dart:async';

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
import 'add_instance.dart';
import 'files.dart';
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
  bool _drawerOpen = false;
  // url → reachable, from a short /health ping (drives the machine status dots).
  final Map<String, bool> _health = {};

  Timer? _sessionsTicker;

  @override
  void initState() {
    super.initState();
    _loadInstances();
    // Tapping a session notification opens it in-place (consistent with the app),
    // not a separate full-screen route.
    if (kCanNotify) onNotifTap = _onNotif;
    // Keep the sidebar live: status dots and model labels drift as sessions run,
    // finish, or switch models — refresh on a gentle cadence.
    _sessionsTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_sessionsLoading) _loadSessions();
      if (mounted) _refreshHealth();
    });
  }

  @override
  void dispose() {
    _sessionsTicker?.cancel();
    if (onNotifTap == _onNotif) onNotifTap = null;
    super.dispose();
  }

  void _onNotif(Map<String, dynamic> m) async {
    if (!mounted) return;
    final url = '${m['url']}';
    final sid = '${m['session'] ?? ''}';
    if (url.isEmpty || sid.isEmpty) return;
    // Cold-start taps can race _loadInstances — make sure the list is in before
    // resolving, then resolve the instance (and its token) from the STORE, not
    // the payload. An unknown/removed instance is ignored gracefully instead of
    // crashing the shell on a null _active.
    if (_loading) {
      final items = await _store.load();
      if (!mounted) return;
      if (_instances.isEmpty) _instances = items;
    }
    Instance? inst;
    for (final i in _instances) {
      if (i.url == url) {
        inst = i;
        break;
      }
    }
    final resolved = inst;
    if (resolved == null) {
      toast(context, 'That machine is no longer saved.', danger: true);
      return;
    }
    setState(() {
      _active = resolved;
      _client = DaemonClient(resolved.url, resolved.token);
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
      _client =
          _active != null ? DaemonClient(_active!.url, _active!.token) : null;
      _loading = false;
    });
    _loadSessions();
    _refreshHealth();
  }

  Future<void> _refreshHealth() async {
    await Future.wait(_instances.map((i) async {
      final ok = await DaemonClient(i.url, i.token).health();
      if (mounted && _health[i.url] != ok) setState(() => _health[i.url] = ok);
    }));
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
      // A slow response for a PREVIOUS instance must not render under (or route
      // taps to) the one selected since.
      if (!identical(c, _client)) return;
      s.sort((a, b) => b.lastActive.compareTo(a.lastActive));
      if (mounted) {
        setState(() {
          _sessions = s;
          _sessionsLoading = false;
        });
      }
    } catch (_) {
      if (identical(c, _client) && mounted) {
        setState(() => _sessionsLoading = false);
      }
    }
  }

  // Start a chat by browsing to a folder in the file explorer and tapping
  // "New chat here" — the explorer doubles as the new-chat picker.
  Future<void> _newSessionFlow() async {
    final c = _client;
    if (c == null) return;
    await presentScreen(
      context,
      builder: (_, close) => FileExplorer(
        client: c,
        title: _active?.label ?? 'Files',
        onClose: close,
        onNewChat: (folder) async {
          try {
            final id = await c.openSession(folder, newConversation: true);
            _openSession(id, 'New session', null);
            _loadSessions();
          } catch (e) {
            if (mounted) toast(context, '$e', danger: true);
          }
          close();
        },
      ),
    );
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

  // Full-screen on phones (QR scan); a compact natural-height dialog on
  // desktop (paste; Esc dismisses, Enter submits).
  Future<void> _addInstanceFlow() async {
    final inst = kMobile
        ? await showModal<Instance>(context, const AddInstanceScreen(),
            width: 480, height: 520)
        : await showAddMachineDialog(context);
    if (inst != null) await _onInstanceAdded(inst);
  }

  Future<void> _renameInstance(Instance inst, String name) async {
    final items = _instances
        .map((e) => e.url == inst.url
            ? Instance(name: name, url: e.url, token: e.token)
            : e)
        .toList();
    await _store.save(items);
    if (!mounted) return;
    setState(() {
      _instances = items;
      if (_active?.url == inst.url) {
        _active = items.firstWhere((e) => e.url == inst.url);
      }
    });
  }

  Future<void> _onInstanceAdded(Instance inst) async {
    final items = [..._instances]..removeWhere((e) => e.url == inst.url);
    items.add(inst);
    await _store.save(items);
    if (!mounted) return;
    setState(() => _instances = items);
    _selectInstance(inst);
    _refreshHealth();
  }

  Future<void> _removeInstance(Instance inst) async {
    final items = [..._instances]..removeWhere((e) => e.url == inst.url);
    await _store.save(items);
    if (!mounted) return;
    setState(() {
      _instances = items;
      if (_active?.url == inst.url) {
        _active = items.isNotEmpty ? items.first : null;
        _client =
            _active != null ? DaemonClient(_active!.url, _active!.token) : null;
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
        onAddInstance: _addInstanceFlow,
        onRenameInstance: _renameInstance,
        onRemoveInstance: _removeInstance,
        onSessionDeleted: _onSessionDeleted,
        health: _health,
        onRefreshHealth: _refreshHealth,
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
        body: Center(
            child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.fg3))),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      // Narrow window → keep the native shell but collapse the sidebar to a drawer.
      if (c.maxWidth < kShellCompact) {
        // Full-width drawer on phones; a capped one on a shrunk desktop window.
        final drawerW =
            kMobile ? c.maxWidth : (c.maxWidth * 0.86).clamp(280.0, 360.0);
        // Back from an open session: reveal the sessions drawer FIRST, then a
        // second back exits. (Only intercept when a session is open and the drawer
        // is closed; from the open drawer or the home placeholder, back exits.)
        return PopScope(
          canPop: _drawerOpen || _sessionId == null,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _scaffoldKey.currentState?.openDrawer();
          },
          child: Scaffold(
            key: _scaffoldKey,
            backgroundColor: AppColors.canvas,
            onDrawerChanged: (open) => setState(() => _drawerOpen = open),
            // Wider left-edge swipe target on phones so the sidebar is easy to pull open.
            drawerEdgeDragWidth: kMobile ? 56 : 24,
            drawer: Drawer(
              width: drawerW,
              backgroundColor: AppColors.bg,
              shape: const RoundedRectangleBorder(),
              child: SafeArea(
                  child: _sidebar(
                      onAfterPick: () =>
                          _scaffoldKey.currentState?.closeDrawer())),
            ),
            // Narrow: the toolbar's sidebar-toggle is at the far left under the
            // traffic lights, so inset the whole pane below them.
            body: SafeArea(
              child: Padding(
                padding: EdgeInsets.only(top: kMacOS ? kMacTitlebar : 0),
                child: _mainPane(
                    onMenu: () => _scaffoldKey.currentState?.openDrawer()),
              ),
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
            const VerticalDivider(
                width: 1, thickness: 1, color: AppColors.border),
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
            Text('Recent sessions', style: display(24)),
            const SizedBox(height: 6),
            Text('Pick up where you left off, or start a new chat from Browse.',
                style: sans(12.5, height: 1.4, color: AppColors.fg3)),
            const SizedBox(height: 16),
            if (_sessionsLoading && _sessions == null)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.fg3))))
            else if (sessions.isEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text('No sessions yet.',
                      style: sans(12.5, color: AppColors.fg4)))
            else
              ...sessions.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: AppCard(
                      onTap: () => _openSession(s.id, s.title, s.profile),
                      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.title.isEmpty ? '(untitled)' : s.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: sans(13, color: AppColors.fg1)),
                                const SizedBox(height: 2),
                                Text(
                                    lastPathSegment(s.folder,
                                        ifEmpty: s.folder),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono(10.5, color: AppColors.fg4)),
                              ]),
                        ),
                        const SizedBox(width: 8),
                        Text(relativeTime(s.lastActive),
                            style: mono(10, color: AppColors.fg4)),
                      ]),
                    ),
                  )),
          ],
        ),
      ),
    );
  }

  // When collapsed, overlay a sidebar-toggle on the welcome/empty states.
  Widget _withMenu(VoidCallback? onMenu, Widget child) {
    if (onMenu == null) return child;
    return Stack(children: [
      child,
      Positioned(
          top: 6,
          left: 6,
          child: IconBtn('sidebar', tooltip: 'Sidebar', onTap: onMenu)),
    ]);
  }

  Widget _welcome() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(R.card),
                      border: Border.all(color: AppColors.border)),
                  child: const AppIcon('cpu', size: 24, color: AppColors.fg3),
                ),
              ),
              const SizedBox(height: 16),
              Text('No instance connected',
                  textAlign: TextAlign.center,
                  style: sans(15, color: AppColors.fg1)),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                    style: sans(12.5, height: 1.5, color: AppColors.fg3),
                    children: [
                      const TextSpan(text: 'Run '),
                      TextSpan(
                          text: 'snippet serve',
                          style: mono(12, color: AppColors.fg2)),
                      const TextSpan(
                          text:
                              ' on a machine, then paste the connection string it prints.'),
                    ]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Center(
                  child: PillBtn('Add machine',
                      icon: 'plus', onTap: _addInstanceFlow)),
            ]),
      ),
    );
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
  final VoidCallback onAddInstance;
  final void Function(Instance, String) onRenameInstance;
  final void Function(Instance) onRemoveInstance;
  final void Function(String id) onSessionDeleted;
  final Map<String, bool> health;
  final VoidCallback onRefreshHealth;
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
    required this.onAddInstance,
    required this.onRenameInstance,
    required this.onRemoveInstance,
    required this.onSessionDeleted,
    required this.health,
    required this.onRefreshHealth,
  });
  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  // The session list now lives in the shell (passed via widget.sessions); the
  // sidebar is presentational, so opening the drawer doesn't refetch.
  String _filter = 'all'; // all | input | running | done
  final _machineKey = GlobalKey(); // anchors the desktop machine popover

  List<SessionInfo>? get _sessions => widget.sessions;
  bool get _loading => widget.sessionsLoading;

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
    presentScreen(context,
        builder: (_, close) => _SettingsPanel(
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
      color: AppColors.bg, // shell surface — darker than the chat canvas
      child: Column(children: [
        SizedBox(
            height:
                kMacOS ? kMacTitlebar + 6 : 10), // clear the window controls
        _machineHeader(),
        _navRow('search', 'Search', onTap: hasClient ? _openSearch : null),
        // Browse doubles as the new-chat entry point ("New chat here" in a folder).
        _navRow('folder', 'Browse',
            sub: 'files · new chat',
            onTap: hasClient ? widget.onNewSession : null),
        const SizedBox(height: 4),
        // Pinned above the list (phones): only the grouped sessions below scroll.
        if (kMobile && hasClient && (widget.sessions?.isNotEmpty ?? false))
          Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: _filterChips(widget.sessions!)),
        Expanded(
          child: !hasClient
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text('Add a machine to begin.',
                          textAlign: TextAlign.center,
                          style: sans(12.5, color: AppColors.fg4))))
              : _sessionList(),
        ),
        // Mobile keeps the Settings footer; desktop has the gear in the header.
        if (kMobile) ...[
          const Divider(height: 1, thickness: 1, color: AppColors.border),
          _footer(),
        ],
      ]),
    );
  }

  // The sidebar/drawer reads bigger on phones than on desktop.
  double get _navText => kMobile ? 16.5 : 13;
  double get _navIcon => kMobile ? 22 : 16;
  double get _navPadV => kMobile ? 13 : 8;
  double get _rowTitle => kMobile ? 14.5 : 12.5;
  double get _rowTime => kMobile ? 11.5 : 10;

  Widget _navRow(String icon, String label,
      {String? sub, VoidCallback? onTap, bool active = false}) {
    // Desktop: flat rounded rows matching the thread list (no sub line).
    if (!kMobile) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 1),
        child: Material(
          color: active ? AppColors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(R.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(R.sm),
            onTap: onTap,
            child: Opacity(
              opacity: onTap == null ? 0.45 : 1,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(children: [
                  AppIcon(icon, size: 15, color: AppColors.fg3),
                  const SizedBox(width: 10),
                  Text(label, style: sans(12.5, color: AppColors.fg1)),
                ]),
              ),
            ),
          ),
        ),
      );
    }
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
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: sans(_navText, color: AppColors.fg1)),
                      if (sub != null)
                        Text(sub, style: sans(12, color: AppColors.fg4)),
                    ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  static bool _statusMatch(String filter, SessionInfo s) => switch (filter) {
        'input' => s.status == 'waiting_for_input',
        'running' => s.status == 'running',
        'done' => s.status != 'waiting_for_input' && s.status != 'running',
        _ => true,
      };

  // Claude-style recency buckets (from lastActive).
  static String _bucket(int unixSec) {
    if (unixSec == 0) return 'Older';
    final now = DateTime.now();
    final t = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    if (days <= 0) return 'Today';
    if (days < 7) return 'This week';
    if (days < 14) return 'Last week';
    if (t.year == now.year) return 'This year';
    return 'Older';
  }

  Widget _sessionList() {
    if (_loading && _sessions == null) {
      return const Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.fg3)));
    }
    final all = _sessions ?? const <SessionInfo>[];
    if (all.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('No chats yet.',
                  style: sans(12.5, color: AppColors.fg4))));
    }
    // Group by recency; the list is already recency-sorted, so buckets are contiguous.
    final list = all.where((s) => _statusMatch(_filter, s)).toList();
    final children = <Widget>[];
    String? bucket;
    for (final s in list) {
      final b = _bucket(s.lastActive);
      if (b != bucket) {
        bucket = b;
        // Quieter, smaller bucket labels on desktop (flat thread list).
        children.add(kMobile
            ? Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                child: SectionLabel(b))
            : Padding(
                padding: const EdgeInsets.fromLTRB(10, 16, 4, 4),
                child: Text(b,
                    style: sans(10.5,
                        weight: FontWeight.w500,
                        spacing: 0.4,
                        color: AppColors.fg4))));
      }
      children.add(kMobile
          ? Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _sessionCard(s))
          : Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: _sessionRow(s)));
    }
    if (list.isEmpty) {
      children.add(Padding(
          padding: const EdgeInsets.all(20),
          child: Text('Nothing here.',
              textAlign: TextAlign.center,
              style: sans(12.5, color: AppColors.fg4))));
    }
    return ListView(
        padding: EdgeInsets.fromLTRB(kMobile ? 12 : 8, 2, kMobile ? 12 : 8, 12),
        children: children);
  }

  Widget _filterChips(List<SessionInfo> all) {
    const items = [
      ('all', 'All'),
      ('input', 'Needs input'),
      ('running', 'Running'),
      ('done', 'Done')
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
        child: Row(children: [
          for (final (val, label) in items) ...[
            _chip(val, label, all.where((s) => _statusMatch(val, s)).length),
            const SizedBox(width: 7),
          ],
        ]),
      ),
    );
  }

  Widget _chip(String val, String label, int n) {
    final sel = _filter == val;
    return Material(
      color: sel ? AppColors.fg1 : AppColors.surface2,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        hoverColor: sel
            ? Colors.transparent
            : null, // no raise on the light selected chip
        onTap: () => setState(() => _filter = val),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          child: Text('$label $n',
              style: sans(12.5,
                  weight: FontWeight.w500,
                  color: sel ? AppColors.bg : AppColors.fg3)),
        ),
      ),
    );
  }

  // Desktop: flat native thread row — no card chrome, rounded hover, a status
  // dot only when it means something (needs input / running).
  Widget _sessionRow(SessionInfo s) {
    final selected = s.id == widget.selectedSessionId;
    final waiting = s.status == 'waiting_for_input';
    final running = s.status == 'running';
    return Material(
      color: selected ? AppColors.surface2 : Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.sm),
        onTap: () => widget.onOpenSession(s.id, s.title, s.profile),
        onLongPress: () => _sessionActions(s),
        onSecondaryTap: () => _sessionActions(s),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            if (waiting || running) ...[
              Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      color: waiting ? AppColors.accent : AppColors.run,
                      shape: BoxShape.circle)),
              const SizedBox(width: 8),
            ],
            Expanded(
                child: Text(s.title.isEmpty ? '(untitled)' : s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(12.5,
                        color: selected ? AppColors.fg1 : AppColors.fg2))),
            const SizedBox(width: 8),
            Text(relativeTime(s.lastActive),
                style: mono(10,
                    color: waiting ? AppColors.accent : AppColors.fg4)),
          ]),
        ),
      ),
    );
  }

  Widget _sessionCard(SessionInfo s) {
    final selected = s.id == widget.selectedSessionId;
    final (Color dot, String word) = switch (s.status) {
      'running' => (AppColors.run, 'Running'),
      'waiting_for_input' => (AppColors.accent, 'Needs input'),
      'completed' => (AppColors.fg3, 'Done'),
      'failed' => (AppColors.fg3, 'Failed'),
      _ => (AppColors.fg3, 'Idle'),
    };
    final folder = lastPathSegment(s.folder, ifEmpty: '');
    final statusSize = kMobile ? 12.5 : 11.5;
    return Material(
      color: selected ? AppColors.accentBg : AppColors.surface1,
      borderRadius: BorderRadius.circular(R.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.card),
        onTap: () => widget.onOpenSession(s.id, s.title, s.profile),
        onLongPress: () => _sessionActions(s),
        onSecondaryTap: () => _sessionActions(s),
        child: Container(
          padding: EdgeInsets.all(kMobile ? 16 : 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(R.card),
            border: Border.all(
                color: selected ? AppColors.accentLine : AppColors.border),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(s.title.isEmpty ? '(untitled)' : s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(_rowTitle, color: AppColors.fg1))),
              const SizedBox(width: 8),
              Text(relativeTime(s.lastActive),
                  style: mono(_rowTime, color: AppColors.fg4)),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Container(
                  width: 7,
                  height: 7,
                  decoration:
                      BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(word, style: sans(statusSize, color: dot)),
              if (folder.isNotEmpty)
                Flexible(
                    child: Text('  ·  $folder',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(statusSize, color: AppColors.fg4))),
            ]),
            if (s.status == 'waiting_for_input') ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(12)),
                child: Text(
                    'Snippet is waiting on your answer — open to respond.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: sans(statusSize, height: 1.4, color: AppColors.fg2)),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  // Long-press / right-click a session → rename or delete.
  void _sessionActions(SessionInfo s) {
    showAppSheet(context,
        title: s.title.isEmpty ? '(untitled)' : s.title,
        child: Column(
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

  Widget _sessionActionTile(String icon, String label,
      {required VoidCallback onTap, bool danger = false}) {
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
    final title = await promptText(context,
        title: 'Rename session',
        initial: s.title,
        hint: 'New title',
        saveLabel: 'Rename');
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
    final ok = await showAppSheet<bool>(context,
        title: 'Delete session?',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.title.isEmpty ? '(untitled session)' : s.title,
                style: sans(13.5, color: AppColors.fg1)),
            const SizedBox(height: 6),
            Text(
                'Permanently removes the conversation. The folder and its files are untouched.',
                style: sans(12, height: 1.45, color: AppColors.fg3)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: Btn('Cancel',
                      variant: BtnVariant.secondary,
                      onTap: () => Navigator.pop(context, false))),
              const SizedBox(width: 10),
              Expanded(
                  child: Btn('Delete',
                      variant: BtnVariant.danger,
                      icon: 'trash',
                      onTap: () => Navigator.pop(context, true))),
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
    return _navRow('settings', 'Settings',
        onTap: widget.client != null ? _openSettings : null);
  }

  // ---- machines ----

  /// The sidebar header IS the machine switcher: active machine label in
  /// display type with a live dot + chevron, host underneath, refresh trailing.
  /// Edge-to-edge tap target; hover raise comes from the global theme.
  Widget _machineHeader() {
    final a = widget.active;
    final ok = a == null ? null : widget.health[a.url];
    final hasClient = widget.client != null;
    return Material(
      key: _machineKey,
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.instances.isEmpty ? widget.onAddInstance : _openMachines,
        child: Padding(
          padding:
              EdgeInsets.fromLTRB(16, kMobile ? 14 : 12, 8, kMobile ? 14 : 12),
          child: Row(children: [
            Expanded(
              child: a == null
                  ? Row(children: [
                      const AppIcon('plus', size: 18, color: AppColors.fg1),
                      const SizedBox(width: 9),
                      Text('Add machine', style: display(kMobile ? 20 : 17)),
                    ])
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Flexible(
                              child: Text(a.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: display(kMobile ? 20 : 17))),
                          const SizedBox(width: 8),
                          Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                  color:
                                      ok == true ? AppColors.ok : AppColors.fg4,
                                  shape: BoxShape.circle)),
                          const SizedBox(width: 6),
                          const AppIcon('chevron-down',
                              size: 16, color: AppColors.fg3),
                        ]),
                        const SizedBox(height: 2),
                        Text(hostOf(a.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mono(11, color: AppColors.fg4)),
                      ],
                    ),
            ),
            const SizedBox(width: 6),
            IconBtn('refresh',
                size: 30,
                iconSize: 15,
                tooltip: 'Refresh',
                onTap:
                    hasClient && !_loading ? widget.onRefreshSessions : null),
            if (!kMobile)
              IconBtn('settings',
                  size: 30,
                  iconSize: 15,
                  tooltip: 'Settings',
                  onTap: hasClient ? _openSettings : null),
          ]),
        ),
      ),
    );
  }

  /// Machine list: bottom sheet on phones, a popover anchored to the block on
  /// desktop. Same rows + "Add machine" footer either way.
  Future<void> _openMachines() async {
    widget.onRefreshHealth();
    final content = _MachineList(
      instances: widget.instances,
      active: widget.active,
      health: widget.health,
      onSelect: widget.onSelectInstance,
      onAdd: widget.onAddInstance,
      onManage: _machineActions,
    );
    if (kMobile) {
      await showAppSheet(context, title: 'Machines', child: content);
      return;
    }
    final box = _machineKey.currentContext!.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    await showGeneralDialog(
      context: context,
      barrierDismissible: true, // click-away and Esc dismiss
      barrierLabel: 'machines',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, __, ___) => Stack(children: [
        // Inset from the edge-to-edge header so it reads as a popover.
        Positioned(
          left: origin.dx + 10,
          top: origin.dy + box.size.height + 4,
          width: box.size.width - 20,
          child: Material(
            color: AppColors.surface1,
            borderRadius: BorderRadius.circular(R.card),
            elevation: 12,
            shadowColor: Colors.black87,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(R.card),
                border: Border.all(color: AppColors.border2),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(child: content),
              ),
            ),
          ),
        ),
      ]),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: child),
    );
  }

  // Overflow / long-press on a machine row → rename or remove (existing flows).
  void _machineActions(Instance i) {
    showAppSheet(context,
        title: i.label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sessionActionTile('edit', 'Rename', onTap: () {
              Navigator.pop(context);
              _renameMachine(i);
            }),
            _sessionActionTile('trash', 'Remove', danger: true, onTap: () {
              Navigator.pop(context);
              _confirmRemoveMachine(i);
            }),
          ],
        ));
  }

  Future<void> _renameMachine(Instance i) async {
    final name = await promptText(context,
        title: 'Rename machine',
        initial: i.label,
        hint: 'Machine name',
        saveLabel: 'Rename');
    if (name == null || name.isEmpty) return;
    widget.onRenameInstance(i, name);
  }

  Future<void> _confirmRemoveMachine(Instance i) async {
    final ok = await showAppSheet<bool>(context,
        title: 'Remove machine?',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(i.label, style: sans(13.5, color: AppColors.fg1)),
            const SizedBox(height: 6),
            Text(
                'Removes the saved connection from this app. The machine and its sessions are untouched.',
                style: sans(12, height: 1.45, color: AppColors.fg3)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: Btn('Cancel',
                      variant: BtnVariant.secondary,
                      onTap: () => Navigator.pop(context, false))),
              const SizedBox(width: 10),
              Expanded(
                  child: Btn('Remove',
                      variant: BtnVariant.danger,
                      icon: 'trash',
                      onTap: () => Navigator.pop(context, true))),
            ]),
          ],
        ));
    if (ok == true) widget.onRemoveInstance(i);
  }
}

/// Rows for the machine popover/sheet: live dot (re-pinged on open), label,
/// host, trailing overflow. Pops itself before invoking any callback.
class _MachineList extends StatefulWidget {
  final List<Instance> instances;
  final Instance? active;
  final Map<String, bool> health;
  final void Function(Instance) onSelect;
  final VoidCallback onAdd;
  final void Function(Instance) onManage;
  const _MachineList({
    required this.instances,
    required this.active,
    required this.health,
    required this.onSelect,
    required this.onAdd,
    required this.onManage,
  });
  @override
  State<_MachineList> createState() => _MachineListState();
}

class _MachineListState extends State<_MachineList> {
  late final Map<String, bool> _h = {...widget.health};

  @override
  void initState() {
    super.initState();
    for (final i in widget.instances) {
      DaemonClient(i.url, i.token).health().then((ok) {
        if (mounted && _h[i.url] != ok) setState(() => _h[i.url] = ok);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...widget.instances.map(_row),
          const Divider(height: 13, thickness: 1, color: AppColors.border),
          _addRow(),
        ]);
  }

  Widget _row(Instance i) {
    final selected = i.url == widget.active?.url;
    final ok = _h[i.url];
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        widget.onSelect(i);
      },
      onLongPress: () {
        Navigator.pop(context);
        widget.onManage(i);
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, kMobile ? 9 : 6, 4, kMobile ? 9 : 6),
        child: Row(children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: ok == true ? AppColors.ok : AppColors.fg4,
                  shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(kMobile ? 14 : 12.5, color: AppColors.fg1)),
              const SizedBox(height: 1),
              Text(hostOf(i.url),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(kMobile ? 11 : 10, color: AppColors.fg4)),
            ]),
          ),
          if (selected)
            const AppIcon('check', size: 14, color: AppColors.accent),
          IconBtn('more-vertical', size: 30, iconSize: 15, tooltip: 'Manage',
              onTap: () {
            Navigator.pop(context);
            widget.onManage(i);
          }),
        ]),
      ),
    );
  }

  Widget _addRow() {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        widget.onAdd();
      },
      child: Padding(
        padding:
            EdgeInsets.fromLTRB(14, kMobile ? 11 : 8, 14, kMobile ? 11 : 8),
        child: Row(children: [
          const AppIcon('plus', size: 15, color: AppColors.accent),
          const SizedBox(width: 10),
          Text('Add machine',
              style: sans(kMobile ? 14 : 12.5,
                  weight: FontWeight.w500, color: AppColors.accent)),
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
    final ok = await showAppSheet<bool>(context,
        title: 'Remove instance?',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(inst.label, style: sans(13.5, color: AppColors.fg1)),
            const SizedBox(height: 6),
            Text(
                'Removes the saved connection from this app. The machine and its sessions are untouched.',
                style: sans(12, height: 1.45, color: AppColors.fg3)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: Btn('Cancel',
                      variant: BtnVariant.secondary,
                      onTap: () => Navigator.pop(context, false))),
              const SizedBox(width: 10),
              Expanded(
                  child: Btn('Remove',
                      variant: BtnVariant.danger,
                      icon: 'trash',
                      onTap: () => Navigator.pop(context, true))),
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
                _tile(
                    'cpu',
                    'Models',
                    'Providers & active model',
                    () => presentScreen(context,
                        builder: (_, close) => ModelsScreen(
                            client: widget.client, onClose: close))),
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
        decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(R.md)),
        child: Row(children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                  color: isActive ? AppColors.accent : AppColors.fg4,
                  shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(13, color: AppColors.fg1)),
              const SizedBox(height: 1),
              Text(hostOf(i.url),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(10.5, color: AppColors.fg4)),
            ]),
          ),
          IconBtn('trash',
              size: 32,
              iconSize: 16,
              tooltip: 'Remove',
              onTap: () => _confirmRemove(i)),
        ]),
      ),
    );
  }

  Widget _notifTile() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
          color: AppColors.surface2, borderRadius: BorderRadius.circular(R.md)),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AppColors.surface3,
              borderRadius: BorderRadius.circular(R.sm)),
          child: const AppIcon('zap', size: 15, color: AppColors.fg2),
        ),
        const SizedBox(width: 11),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Notifications', style: sans(13, color: AppColors.fg1)),
            const SizedBox(height: 1),
            Text('Alert when a session needs input or finishes',
                style: sans(11, color: AppColors.fg4)),
          ]),
        ),
        _notifBusy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.fg3))
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
              decoration: BoxDecoration(
                  color: AppColors.surface3,
                  borderRadius: BorderRadius.circular(R.sm)),
              child: AppIcon(icon, size: 15, color: AppColors.fg2),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
