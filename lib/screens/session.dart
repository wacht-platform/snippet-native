import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../models.dart';
import '../notifications.dart';
import '../platform.dart';
import '../theme.dart';
import '../tool_views.dart';
import '../panel.dart';
import '../widgets.dart';
import 'files.dart';
import 'git.dart';

class SessionScreen extends StatefulWidget {
  final DaemonClient client;
  final String sessionId;
  final String title;
  final String? profile;
  /// True when shown as the main pane of the desktop shell (hides its own
  /// back/home chrome — navigation lives in the sidebar).
  final bool embedded;
  const SessionScreen({super.key, required this.client, required this.sessionId, required this.title, this.profile, this.embedded = false});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> with WidgetsBindingObserver {
  WebSocketChannel? _channel;
  HarnessState? _state;
  String? _connError;
  String? _modelLabel;
  String? _currentProfile;
  bool _isCodex = false;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  // Messages sent mid-run, shown optimistically until the daemon applies them as
  // a `steer` event (then reconciled away). Cancelled via the drop_queued input.
  final List<String> _queued = [];
  // Messages sent to the daemon but not yet echoed back as events — shown
  // optimistically (faint) so they don't vanish during the round-trip.
  final List<String> _pending = [];
  // A pending image attachment: local path for the thumbnail + the uploaded
  // daemon path the agent will read_image. _uploading while the upload is in flight.
  String? _localImagePath;
  String? _pendingImagePath;
  bool _uploading = false;
  bool _didInitialScroll = false;
  // Auto-reconnect: backoff timer + attempt counter; _closed stops retries on leave.
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closed = false;
  late String _title;
  // Tracks the last status so we can detect running → paused and flush _queued.
  String? _prevStatus;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    WidgetsBinding.instance.addObserver(this);
    _connect();
    _loadModel();
    reportOpenSession('${widget.client.baseUrl}|${widget.sessionId}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS often drops the socket while backgrounded — reconnect promptly on resume.
    if (state == AppLifecycleState.resumed && !_closed) {
      _reconnectAttempt = 0;
      _connect();
    }
  }

  Future<void> _loadModel() async {
    try {
      final cfg = await widget.client.getConfig();
      final wanted = _currentProfile ?? widget.profile;
      ModelProfile? p;
      if (wanted != null) {
        for (final m in cfg.profiles) {
          if (m.name == wanted) {
            p = m;
            break;
          }
        }
      }
      if (p == null) {
        for (final m in cfg.profiles) {
          if (m.active) {
            p = m;
            break;
          }
        }
      }
      if (mounted) {
        setState(() {
          _modelLabel = p?.name;
          _isCodex = p?.provider == 'chatgpt';
        });
      }
    } catch (_) {}
  }

  void _connect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    if (mounted) setState(() => _connError = null);
    final ch = widget.client.attach(widget.sessionId);
    _channel = ch;
    ch.stream.listen(
      (msg) {
        // Any frame means a healthy socket — reset backoff + clear the banner.
        if (_reconnectAttempt != 0 || _connError != null) {
          _reconnectAttempt = 0;
          if (mounted) setState(() => _connError = null);
        }
        try {
          final j = jsonDecode(msg as String) as Map<String, dynamic>;
          if (!mounted) return;
          final cur = _state;
          final next = (j['wire'] == 'delta' && cur != null) ? cur.applyDelta(j) : HarnessState.fromJson(j);
          final firstLoad = !_didInitialScroll && next.events.isNotEmpty;
          // Auto-follow while pinned to the bottom; the user scrolling up turns it
          // off (and back on when they return) — content growth never does.
          final follow = _stickToBottom;
          // The moment the run pauses (running → not running), auto-submit anything
          // the user queued while it was busy.
          if (_prevStatus == 'running' && next.status != 'running' && _queued.isNotEmpty) {
            for (final m in _queued) {
              _send({'kind': 'user_message', 'value': m});
              _pending.add(m);
            }
            _queued.clear();
          }
          _prevStatus = next.status;
          // Drop pending bubbles once the daemon echoes them back as events.
          if (j['wire'] == 'delta') {
            for (final e in ((j['new_events'] as List?) ?? const [])) {
              final m = e as Map;
              if (m['kind'] == 'user_input' || m['kind'] == 'steer') {
                _pending.remove(m['text']?.toString());
              }
            }
          } else {
            _pending.clear(); // full snapshot is authoritative
          }
          setState(() {
            _state = next;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (firstLoad) {
              _didInitialScroll = true;
              // Jump to the bottom on open; re-jump to catch late layout growth
              // (markdown/code blocks measure after the first frame).
              _toBottom(jump: true);
              Future.delayed(const Duration(milliseconds: 120), () { if (mounted) _toBottom(jump: true); });
              Future.delayed(const Duration(milliseconds: 350), () { if (mounted) _toBottom(jump: true); });
            } else if (follow) {
              // Jump (not animate) so it reaches the true bottom even as a streaming
              // reply keeps growing; a short re-jump catches late markdown layout.
              _toBottom(jump: true);
              Future.delayed(const Duration(milliseconds: 100), () { if (mounted && _stickToBottom) _toBottom(jump: true); });
            }
          });
        } catch (_) {}
      },
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );
  }

  // Reconnect with exponential backoff (1,2,4,8,15,30s). Deduped so onError+onDone
  // don't double-schedule; reset to 0 on any healthy frame or app-resume.
  void _scheduleReconnect() {
    if (_closed) return;
    if (_reconnectTimer?.isActive ?? false) return; // already pending
    _channel = null;
    const steps = [1, 2, 4, 8, 15, 30];
    final delay = steps[_reconnectAttempt.clamp(0, steps.length - 1)];
    _reconnectAttempt++;
    if (mounted) setState(() => _connError = 'Reconnecting…');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_closed) _connect();
    });
  }

  // Whether to keep pinning to the latest message. Only the USER's own scrolling
  // flips this (see the NotificationListener) — content growth never does, so a
  // streaming reply keeps reaching the true bottom instead of falling behind.
  bool _stickToBottom = true;

  // True when the view is pinned at (or near) the latest message.
  bool _atBottom() {
    if (!_scroll.hasClients) return true;
    return _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
  }

  // Update the stick flag from a user-driven scroll (drag or settle).
  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      _stickToBottom = _atBottom();
    } else if (n is ScrollEndNotification) {
      _stickToBottom = _atBottom();
    }
    return false;
  }

  void _toBottom({bool jump = false}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _send(Map<String, dynamic> m) => _channel?.sink.add(jsonEncode(m));

  void _sendMessage() {
    final t = _input.text.trim();
    final img = _pendingImagePath;
    if (t.isEmpty && img == null) return;
    final running = _state?.status == 'running';
    // Attach the uploaded image as an explicit read_image instruction so the agent
    // reliably views it this turn.
    final marker = '[attached image — call read_image on this exact path to view it: $img]';
    final msg = img == null ? t : (t.isEmpty ? marker : '$t\n\n$marker');
    setState(() {
      if (running) {
        // Busy: hold it and auto-submit when the run pauses (don't steer mid-task).
        _queued.add(msg);
      } else {
        _send({'kind': 'user_message', 'value': msg});
        _pending.add(msg); // show it until the daemon echoes it back
      }
      _localImagePath = null;
      _pendingImagePath = null;
      _uploading = false;
    });
    _input.clear();
    // Sending is an explicit action — re-pin and jump to the bottom.
    _stickToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(jump: true));
  }

  Future<void> _attachImage() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2200);
      if (x == null) return;
      setState(() {
        _localImagePath = x.path;
        _pendingImagePath = null;
        _uploading = true;
      });
      final bytes = await x.readAsBytes();
      final path = await widget.client.uploadFile(bytes, name: x.name);
      if (!mounted) return;
      setState(() {
        _pendingImagePath = path;
        _uploading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        _toast('$e');
      }
    }
  }

  // Cancel everything still queued for this run (drop_queued clears the daemon's
  // pending buffer; if some already applied, those stay as real bubbles).
  // Held messages were never sent to the daemon yet — just drop them locally.
  void _cancelQueued() => setState(() => _queued.clear());

  // Drop queued items that the daemon has now applied (they arrive as `steer`
  // events). FIFO match so duplicate texts reconcile in order.
  // Display label for a held message — hide the verbose image marker.
  String _queuedLabel(String m) {
    if (m.startsWith('[attached image')) return '🖼 image';
    final i = m.indexOf('\n\n[attached image');
    return i >= 0 ? '${m.substring(0, i)}  🖼' : m;
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  void dispose() {
    _closed = true;
    _reconnectTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    reportOpenSession('');
    _channel?.sink.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _pendingApproval(List<Map<String, dynamic>> events) {
    for (var i = events.length - 1; i >= 0; i--) {
      final k = events[i]['kind'];
      if (k == 'approval_request') return true;
      if (k == 'tool_result' || k == 'assistant_text') return false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final status = s?.status ?? 'connecting';
    final running = status == 'running';
    final waiting = status == 'waiting_for_input';
    final events = s?.events ?? const [];
    final items = _transcript(events);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SnAppBar(
            title: _title.isEmpty ? 'session' : _title,
            subtitle: s != null && s.workspace.isNotEmpty ? s.workspace : null,
            onBack: widget.embedded ? null : () => Navigator.pop(context),
            actions: [
              if (!widget.embedded)
                IconBtn('home', tooltip: 'Instances', onTap: () => Navigator.popUntil(context, (r) => r.isFirst)),
              if (running) IconBtn('stop', tooltip: 'Stop', onTap: () => _send({'kind': 'interrupt'})),
              _menu(s),
            ],
          ),
          _statusStrip(s, running),
          if (_connError != null) _disconnectedBanner(),
          Expanded(
            child: s == null
                ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)))
                : NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                    children: [
                      if (items.isEmpty && !running)
                        const EmptyState(icon: 'terminal', title: 'Session ready', body: 'Send a task to get started.'),
                      ...items,
                      // Optimistic bubbles for messages sent but not yet echoed.
                      for (final p in _pending)
                        Opacity(opacity: 0.5, child: Padding(padding: const EdgeInsets.only(bottom: 12), child: Bubble(mine: true, text: _queuedLabel(p)))),
                      if (running) ...[const SizedBox(height: 12), const _TypingDots()],
                      if (_queued.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        for (final q in _queued) _QueuedBubble(text: _queuedLabel(q), onCancel: _cancelQueued),
                      ],
                      if (waiting && _pendingApproval(events)) ...[const SizedBox(height: 12), _ApprovalBar(onSend: _send)]
                      else if (waiting && s.pendingQuestion != null) ...[const SizedBox(height: 12), _QuestionBar(question: s.pendingQuestion!, onSend: _send)],
                    ],
                  ),
                ),
          ),
          _inputBar(running),
        ]),
      ),
    );
  }

  Future<void> _renameCurrent() async {
    final title = await promptText(context,
        title: 'Rename session', initial: _title, hint: 'New title', saveLabel: 'Rename');
    if (title == null) return;
    try {
      await widget.client.renameSession(widget.sessionId, title);
      if (mounted) setState(() => _title = title);
    } catch (e) {
      if (mounted) _toast('$e');
    }
  }

  Widget _menu(HarnessState? s) {
    final view = View.of(context);
    final desktop = view.physicalSize.width / view.devicePixelRatio >= kDesktopBreakpoint;
    if (!desktop) {
      return IconBtn('more-vertical', tooltip: 'Actions', onTap: () => _openActions(s));
    }
    return PopupMenuButton<VoidCallback>(
      color: AppColors.surface2,
      elevation: 8,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 260),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: const BorderSide(color: AppColors.border2)),
      icon: const AppIcon('more-vertical', color: AppColors.fg2),
      tooltip: 'Actions',
      onSelected: (fn) => fn(),
      itemBuilder: (_) => _actionItems(s),
    );
  }

  List<PopupMenuEntry<VoidCallback>> _actionItems(HarnessState? s) {
    final manual = (s?.approvalMode ?? 'auto') == 'manual';
    final ws = s?.workspace ?? '';
    PopupMenuItem<VoidCallback> item(String icon, String label, VoidCallback fn, {String? value}) =>
        PopupMenuItem<VoidCallback>(
          value: fn,
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            AppIcon(icon, size: 14, color: AppColors.fg2),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: sans(12.5, color: AppColors.fg1))),
            if (value != null) Text(value, style: mono(11, color: AppColors.fg4)),
          ]),
        );
    return [
      item('cpu', 'Switch model', _switchModel, value: _modelLabel),
      item('edit', 'Rename session', _renameCurrent),
      item('shield', 'Approval mode', () {
        _send({'kind': 'set_mode', 'value': manual ? 'auto' : 'manual'});
        _toast(manual ? 'Approval: auto' : 'Approval: ask');
      }, value: manual ? 'Ask' : 'Auto'),
      const PopupMenuDivider(),
      item('git-branch', 'Git', () => presentScreen(context, builder: (_, close) => GitScreen(client: widget.client, sessionId: widget.sessionId, onClose: close))),
      item('folder', 'Open files', () {
        final name = ws.split('/').where((p) => p.isNotEmpty).lastOrNull ?? 'Files';
        presentScreen(context, builder: (_, close) => FileExplorer(client: widget.client, title: name, start: ws.isEmpty ? null : ws, onClose: close));
      }),
      item('terminal', 'Run command', _showExec),
      const PopupMenuDivider(),
      item('minimize', 'Compact history', () {
        _send({'kind': 'compact'});
        _toast('Compacting history');
      }),
      item('history', 'Checkpoints', _showCheckpoints),
      item('activity', 'Usage', _showUsage),
    ];
  }

  void _openActions(HarnessState? s) {
    final manual = (s?.approvalMode ?? 'auto') == 'manual';
    final ws = s?.workspace ?? '';
    void run(VoidCallback f) {
      Navigator.pop(context);
      f();
    }

    showAppSheet(context, title: 'Actions', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Session'),
        _actionTile('cpu', 'Switch model', value: _modelLabel, onTap: () => run(_switchModel)),
        _actionTile('edit', 'Rename session', onTap: () => run(_renameCurrent)),
        _actionTile('shield', 'Approval mode', value: manual ? 'Ask' : 'Auto', onTap: () => run(() {
          _send({'kind': 'set_mode', 'value': manual ? 'auto' : 'manual'});
          _toast(manual ? 'Approval: auto' : 'Approval: ask');
        })),
        const SizedBox(height: 12),
        const SectionLabel('Workspace'),
        _actionTile('git-branch', 'Git', onTap: () => run(() => presentScreen(context,
            builder: (_, close) => GitScreen(client: widget.client, sessionId: widget.sessionId, onClose: close)))),
        _actionTile('folder', 'Open files', onTap: () => run(() {
          final name = ws.split('/').where((p) => p.isNotEmpty).lastOrNull ?? 'Files';
          presentScreen(context, builder: (_, close) => FileExplorer(client: widget.client, title: name, start: ws.isEmpty ? null : ws, onClose: close));
        })),
        _actionTile('terminal', 'Run command', onTap: () => run(_showExec)),
        const SizedBox(height: 12),
        const SectionLabel('History'),
        _actionTile('minimize', 'Compact history', onTap: () => run(() {
          _send({'kind': 'compact'});
          _toast('Compacting history');
        })),
        _actionTile('history', 'Checkpoints', onTap: () => run(_showCheckpoints)),
        _actionTile('activity', 'Usage', onTap: () => run(_showUsage)),
        const SizedBox(height: 4),
      ],
    ));
  }

  Widget _actionTile(String icon, String label, {String? value, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(R.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(R.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: AppColors.surface3, borderRadius: BorderRadius.circular(R.sm)),
                child: AppIcon(icon, size: 15, color: AppColors.fg2),
              ),
              const SizedBox(width: 11),
              Expanded(child: Text(label, style: sans(13, color: AppColors.fg1))),
              if (value != null) Text(value, style: mono(11, color: AppColors.fg3)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _statusStrip(HarnessState? s, bool running) {
    final chips = <Widget>[
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: running ? AppColors.run : AppColors.fg2, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(running ? 'Running' : 'Idle', style: sans(11, weight: FontWeight.w500, color: running ? AppColors.run : AppColors.fg2)),
      ]),
    ];
    if (_modelLabel != null) chips.add(_StatMeta(icon: 'cpu', label: _modelLabel!));
    if (s != null) {
      if (s.contextWindow > 0 && s.lastPromptTokens > 0) {
        chips.add(_StatMeta(icon: 'activity', label: '${(s.lastPromptTokens / s.contextWindow * 100).clamp(0, 999).round()}% ctx'));
      }
      if (s.totalTokens > 0) chips.add(_StatMeta(icon: 'zap', label: '${fmtSi(s.totalTokens)} tok'));
      chips.add(_StatMeta(icon: 'shield', label: s.approvalMode == 'auto' ? 'Auto-approve' : 'Ask', tone: s.approvalMode == 'auto' ? 'accent' : 'default'));
      final rp = s.ratePrimary;
      if (_isCodex && rp != null) chips.add(_StatMeta(icon: 'clipboard', label: '${rateWindowLabel(rp.windowMinutes)} · ${rp.leftPercent.round()}%', tone: 'run'));
    }
    return Container(
      height: 38,
      decoration: const BoxDecoration(color: AppColors.surface1, border: Border(bottom: BorderSide(color: AppColors.border))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          for (var i = 0; i < chips.length; i++) ...[if (i > 0) const SizedBox(width: 12), chips[i]],
        ]),
      ),
    );
  }

  Widget _disconnectedBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: AppColors.dangerBg, border: Border(bottom: BorderSide(color: AppColors.danger.withValues(alpha: 0.25)))),
      child: Row(children: [
        const AppIcon('wifi-off', size: 15, color: AppColors.danger),
        const SizedBox(width: 9),
        Expanded(child: Text(_connError ?? 'Disconnected', style: sans(12, height: 1.3, color: AppColors.fg1))),
        GestureDetector(
          onTap: () {
            _reconnectAttempt = 0;
            _connect();
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const AppIcon('refresh', size: 13, color: AppColors.danger),
            const SizedBox(width: 5),
            Text('Retry now', style: sans(12, weight: FontWeight.w600, color: AppColors.danger)),
          ]),
        ),
      ]),
    );
  }

  Widget _inputBar(bool running) {
    final hasText = _input.text.trim().isNotEmpty;
    final canSend = (hasText || _pendingImagePath != null) && !_uploading;
    return Container(
      padding: EdgeInsets.fromLTRB(12, 4, 12, 8 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_localImagePath != null) _imageChip(),
        // One compact field with + (attach) and send inline; no top separator.
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(R.md + 3),
          ),
          padding: const EdgeInsets.all(4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconBtn('plus', size: 30, iconSize: 18, tooltip: 'Attach image', onTap: _uploading ? null : _attachImage),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  cursorColor: AppColors.accent,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _sendMessage(),
                  style: sans(13.5, height: 1.4, color: AppColors.fg1),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: InputBorder.none,
                    hintText: 'Message snippet…',
                    hintStyle: sans(13.5, color: AppColors.fg4),
                  ),
                ),
              ),
            ),
            _SendBtn(enabled: canSend, onTap: canSend ? _sendMessage : null),
          ]),
        ),
      ]),
    );
  }

  Widget _imageChip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _localImagePath != null
              ? Image.file(File(_localImagePath!), width: 40, height: 40, fit: BoxFit.cover)
              : Container(width: 40, height: 40, color: AppColors.surface3),
        ),
        const SizedBox(width: 9),
        if (_uploading) ...[
          const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)),
          const SizedBox(width: 8),
          Text('Uploading…', style: sans(11.5, color: AppColors.fg3)),
        ] else
          Text('Image attached', style: sans(11.5, color: AppColors.fg2)),
        const Spacer(),
        IconBtn('x', size: 30, iconSize: 16, onTap: () => setState(() {
          _localImagePath = null;
          _pendingImagePath = null;
          _uploading = false;
        })),
      ]),
    );
  }

  // ---- event → widget (pairs tool_call with its tool_result) ----
  List<Widget> _transcript(List<Map<String, dynamic>> events) {
    final out = <Widget>[];
    Map<String, dynamic>? pending;
    final group = <Widget>[]; // consecutive tool lines, grouped together

    void flushPending() {
      final p = pending;
      if (p != null) {
        final name = _s(p['tool_name']);
        group.add(ToolLine(tool: name, icon: toolIcon(name), arg: toolArgSummary(name, p['arguments']), done: false, detailBuilder: (ctx) => toolDetailView(ctx, tool: name, args: p['arguments'], result: null)));
        pending = null;
      }
    }

    // Close a run of consecutive tool calls: emit a single grouped block when
    // there are several, or just the one line when it's alone.
    void endTools() {
      flushPending();
      if (group.isEmpty) return;
      if (group.length == 1) {
        out.add(Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: group.first));
      } else {
        out.add(Padding(padding: const EdgeInsets.only(top: 2, bottom: 10), child: _ToolGroup(List.of(group))));
      }
      group.clear();
    }

    for (final e in events) {
      final k = e['kind'] as String? ?? '';
      switch (k) {
        case 'tool_call':
          flushPending();
          // Meta-tools render via their own events (note → note, ask_user →
          // user_question, delegate_task → lane_spawned). Skip their generic tool
          // lines so they don't double up or open a raw-JSON drawer.
          if (_isMetaTool(_s(e['tool_name']))) break;
          pending = e;
        case 'tool_result':
          {
            final p = pending;
            if (p != null) {
              final name = _s(p['tool_name']);
              group.add(ToolLine(tool: name, icon: toolIcon(name), arg: toolArgSummary(name, p['arguments']), out: _resultStatus(e['result']), done: _ok(e['result']), detailBuilder: (ctx) => toolDetailView(ctx, tool: name, args: p['arguments'], result: e['result'])));
              pending = null;
            } else {
              final name = _s(e['tool_name']);
              if (_isMetaTool(name)) break;
              group.add(ToolLine(tool: name, icon: toolIcon(name), out: _resultStatus(e['result']), done: _ok(e['result']), detailBuilder: (ctx) => toolDetailView(ctx, tool: name, args: null, result: e['result'])));
            }
          }
        case 'user_input':
        case 'steer':
          endTools();
          out.add(Padding(padding: const EdgeInsets.only(top: 2, bottom: 14), child: Bubble(mine: true, text: _s(e['text']))));
        case 'assistant_text':
          endTools();
          out.add(Padding(padding: const EdgeInsets.only(top: 2, bottom: 14), child: Bubble(mine: false, text: _s(e['text']))));
        case 'model_error':
          endTools();
          out.add(NoteLine(_s(e['message']), error: true));
        case 'invalid_tool_call':
          endTools();
          out.add(NoteLine('invalid ${_s(e['tool_name'])}: ${_s(e['error'])}', error: true));
        case 'note':
          endTools();
          final entry = _s(e['entry']);
          out.add(_NoteLine(entry, onTap: () => _showNote(entry)));
        case 'system_decision':
          endTools();
          out.add(NoteLine(_s(e['reasoning'])));
        case 'lane_spawned':
          endTools();
          out.add(NoteLine('lane: ${_s(e['title'])}'));
        case 'lane_completed':
          endTools();
          out.add(NoteLine('lane done: ${_s(e['title'])}'));
        case 'user_question':
          endTools();
          final qd = e['questions'];
          final qs = (qd is Map ? qd['questions'] : null) as List?;
          final txt = (qs != null && qs.isNotEmpty && qs.first is Map) ? _s((qs.first as Map)['text']) : '';
          if (txt.isNotEmpty) out.add(Padding(padding: const EdgeInsets.only(top: 2, bottom: 14), child: Bubble(mine: false, text: '❓ $txt')));
        case 'approval_request':
          break; // shown by the approval bar
        default:
          break;
      }
    }
    endTools();
    return out;
  }

  String _s(dynamic v) => v?.toString() ?? '';

  // Meta-tools have dedicated event rendering, so their generic tool lines are skipped.
  bool _isMetaTool(String n) => n == 'note' || n == 'ask_user' || n == 'delegate_task';

  void _showNote(String text) {
    showAppSheet(context, title: 'Note', child: SelectableText(text, style: sans(13.5, height: 1.5, color: AppColors.fg1)));
  }

  // Short result tag shown on the inline line: exit code for bash, else status.
  String _resultStatus(dynamic r) {
    if (r is! Map) return 'done';
    final data = r['data'];
    if (data is Map && data['exit_code'] != null) return 'exit ${data['exit_code']}';
    final st = r['status']?.toString();
    if (st == 'error') return 'error';
    return 'done';
  }

  bool _ok(dynamic r) => !(r is Map && r['status'] == 'error');


  Future<void> _switchModel() async {
    ServerConfig cfg;
    try {
      cfg = await widget.client.getConfig();
    } catch (e) {
      _toast('$e');
      return;
    }
    if (!mounted) return;
    final picked = await showAppSheet<String>(context, title: 'Switch model', child: Column(
      children: cfg.profiles
          .map((p) => Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(R.sm),
                  onTap: () => Navigator.pop(context, p.name),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                    child: Row(children: [
                      const AppIcon('cpu', size: 17, color: AppColors.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(p.name, style: sans(13.5, weight: FontWeight.w500, color: AppColors.fg1)),
                          const SizedBox(height: 2),
                          Text('${p.provider} · ${p.model}', style: mono(11, color: AppColors.fg3)),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ))
          .toList(),
    ));
    if (picked == null) return;
    try {
      await widget.client.setSessionModel(widget.sessionId, picked);
      _toast('Switched to $picked');
      if (mounted) {
        _currentProfile = picked;
        _loadModel();
        _connect();
      }
    } catch (e) {
      _toast('$e');
    }
  }

  void _showExec() {
    final ctrl = TextEditingController();
    String output = '';
    bool busy = false;
    showAppSheet(context, title: 'Run command', child: StatefulBuilder(
      builder: (ctx, setSheet) {
        Future<void> run() async {
          final cmd = ctrl.text.trim();
          if (cmd.isEmpty || busy) return;
          setSheet(() {
            busy = true;
            output = '';
          });
          try {
            final r = await widget.client.exec(widget.sessionId, cmd);
            final so = (r['stdout'] ?? '').toString();
            final se = (r['stderr'] ?? '').toString();
            output = [
              if (so.isNotEmpty) so,
              if (se.isNotEmpty) se,
              'exit ${r['exit_code']}',
            ].join('\n');
          } catch (e) {
            output = '$e';
          }
          setSheet(() => busy = false);
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Runs in the session workspace.', style: sans(11.5, color: AppColors.fg3)),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: AppField(controller: ctrl, mono: true, icon: 'terminal', hint: 'ls -la', onSubmitted: (_) => run())),
            const SizedBox(width: 8),
            Btn(busy ? '\u2026' : 'Run', disabled: busy, onTap: run),
          ]),
          if (output.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.surface2, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(R.md)),
              child: SelectableText(output, style: mono(11.5, height: 1.5, color: AppColors.fg1)),
            ),
          ],
        ]);
      },
    ));
  }

  void _showUsage() {
    final s = _state;
    if (s == null) return;
    showAppSheet(context, title: 'Usage', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (s.contextWindow > 0) ...[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Context window', style: sans(12.5, weight: FontWeight.w500, color: AppColors.fg2)),
          Text('${fmtSi(s.lastPromptTokens)} / ${fmtSi(s.contextWindow)}', style: mono(11.5, color: AppColors.fg3)),
        ]),
        const SizedBox(height: 9),
        Progress(pct: s.lastPromptTokens / s.contextWindow * 100, height: 9),
        const SizedBox(height: 7),
        Text('${(s.lastPromptTokens / s.contextWindow * 100).round()}% used', style: mono(11, color: AppColors.accent)),
        const SizedBox(height: 18),
      ],
      const SectionLabel('Tokens'),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: StatTile(label: '↑ Input', value: fmtSi(s.promptTokens))),
        const SizedBox(width: 8),
        Expanded(child: StatTile(label: '↓ Output', value: fmtSi(s.completionTokens))),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: StatTile(label: '↻ Cached', value: fmtSi(s.cacheReadTokens))),
        const SizedBox(width: 8),
        Expanded(child: StatTile(label: 'Total', value: fmtSi(s.totalTokens), accent: true)),
      ]),
      if (_isCodex && (s.ratePrimary != null || s.rateSecondary != null)) ...[
        const SizedBox(height: 18),
        const SectionLabel('Rate limits · remaining'),
        const SizedBox(height: 8),
        for (final w in [s.ratePrimary, s.rateSecondary])
          if (w != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 11),
              child: Builder(builder: (_) {
                final rem = w.leftPercent;
                final color = rem < 20 ? AppColors.danger : rem < 50 ? AppColors.run : AppColors.ok;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(rateWindowLabel(w.windowMinutes), style: sans(12, color: AppColors.fg2)),
                    Text('${rem.round()}% left', style: mono(11, color: color)),
                  ]),
                  const SizedBox(height: 6),
                  Progress(pct: rem, color: color, height: 6),
                ]);
              }),
            ),
      ],
    ]));
  }

  void _showCheckpoints() {
    final s = _state;
    if (s == null) return;
    final cps = s.checkpoints.reversed.toList();
    showAppSheet(context, title: 'Checkpoints', child: Column(children: [
      if (cps.isEmpty)
        Padding(padding: const EdgeInsets.all(20), child: Text('No checkpoints yet.', style: sans(12.5, color: AppColors.fg3))),
      ...cps.map((c) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.all(13),
              onTap: () => _confirmRewind(c),
              child: Row(children: [
                Container(width: 34, height: 34, decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(9)), child: const AppIcon('history', size: 17, color: AppColors.fg3)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.label.isEmpty ? c.id : c.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13, weight: FontWeight.w500, height: 1.2, color: AppColors.fg1)),
                    const SizedBox(height: 3),
                    Text(c.createdAt, style: mono(11, color: AppColors.fg3)),
                  ]),
                ),
                const AppIcon('rotate', size: 16, color: AppColors.fg4),
              ]),
            ),
          )),
    ]));
  }

  Future<void> _confirmRewind(Checkpoint c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: AppColors.surface1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.border2)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Restore workspace?', style: sans(15, weight: FontWeight.w600, color: AppColors.fg1)),
            const SizedBox(height: 6),
            Text('This rolls the workspace back to “${c.label.isEmpty ? c.id : c.label}”. Changes after this point are discarded.', style: sans(12.5, height: 1.5, color: AppColors.fg3)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: Btn('Cancel', variant: BtnVariant.ghost, onTap: () => Navigator.pop(context, false))),
              const SizedBox(width: 8),
              Expanded(child: Btn('Restore', onTap: () => Navigator.pop(context, true))),
            ]),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    if (mounted) Navigator.pop(context); // close the sheet
    try {
      await widget.client.rewind(widget.sessionId, c.id);
      _toast('Workspace restored');
    } catch (e) {
      _toast('$e');
    }
  }
}

class _StatMeta extends StatelessWidget {
  final String icon, label, tone;
  const _StatMeta({required this.icon, required this.label, this.tone = 'default'});
  @override
  Widget build(BuildContext context) {
    final c = tone == 'accent' ? AppColors.accent : tone == 'run' ? AppColors.run : AppColors.fg2;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AppIcon(icon, size: 12, color: tone == 'default' ? AppColors.fg4 : c),
      const SizedBox(width: 5),
      Text(label, style: mono(11, color: c)),
    ]);
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: const BoxDecoration(
          color: AppColors.surface1,
          border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
          borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomRight: Radius.circular(16), bottomLeft: Radius.circular(5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _c,
            builder: (_, __) {
              final t = ((_c.value + i * 0.18) % 1.0);
              final o = 0.4 + 0.6 * (t < 0.5 ? t * 2 : (1 - t) * 2);
              return Padding(
                padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                child: Opacity(opacity: o, child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.fg3, shape: BoxShape.circle))),
              );
            },
          );
        })),
      ),
    );
  }
}

/// A message sent mid-run, shown right-aligned + dimmed with a cancel (✕) until
/// the daemon applies it (then it's replaced by the real bubble).
/// A run of consecutive tool calls, grouped under a left rule. The "N steps"
/// header toggles the group collapsed/expanded.
class _ToolGroup extends StatefulWidget {
  final List<Widget> children;
  const _ToolGroup(this.children);
  @override
  State<_ToolGroup> createState() => _ToolGroupState();
}

class _ToolGroupState extends State<_ToolGroup> {
  bool _open = true;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.border2, width: 2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(R.sm),
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(R.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: Row(children: [
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const AppIcon('chevron-right', size: 12, color: AppColors.fg4),
                ),
                const SizedBox(width: 6),
                Text('${widget.children.length} steps', style: sans(10.5, color: AppColors.fg4, spacing: 0.5)),
              ]),
            ),
          ),
        ),
        if (_open) ...widget.children,
      ]),
    );
  }
}

class _QueuedBubble extends StatelessWidget {
  final String text;
  final VoidCallback onCancel;
  const _QueuedBubble({required this.text, required this.onCancel});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 5, height: 5, decoration: const BoxDecoration(color: AppColors.fg4, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text('QUEUED', style: sans(10, color: AppColors.fg4, spacing: 0.8)),
          const Spacer(),
          IconBtn('x', size: 26, iconSize: 14, tooltip: 'Cancel', onTap: onCancel),
        ]),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(text, style: sans(13.5, height: 1.5, color: AppColors.fg3)),
        ),
      ]),
    );
  }
}

class _ApprovalBar extends StatelessWidget {
  final void Function(Map<String, dynamic>) onSend;
  const _ApprovalBar({required this.onSend});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: AppColors.accentBg, border: Border.all(color: AppColors.accentLine), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: AppIcon('shield', size: 16, color: AppColors.accent)),
          const SizedBox(width: 9),
          Expanded(child: Text('Approve this action?', style: sans(13, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1))),
        ]),
        const SizedBox(height: 11),
        Row(children: [
          Expanded(child: Btn('Approve', small: true, icon: 'check', onTap: () => onSend({'kind': 'approve'}))),
          const SizedBox(width: 8),
          Expanded(child: Btn('Approve all', small: true, variant: BtnVariant.secondary, icon: 'check-check', onTap: () => onSend({'kind': 'approve_all'}))),
          const SizedBox(width: 8),
          Btn('Deny', small: true, variant: BtnVariant.ghost, onTap: () => onSend({'kind': 'deny'})),
        ]),
      ]),
    );
  }
}

/// An agent note: a clean, left-aligned, readable line (preview up to 4 lines)
/// that opens the full note in a sheet on tap — not a raw-JSON tool drawer.
class _NoteLine extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _NoteLine(this.text, {required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(R.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(R.sm),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(R.sm),
              border: const Border(left: BorderSide(color: AppColors.border2, width: 2)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 1.5), child: AppIcon('edit', size: 12, color: AppColors.fg4)),
              const SizedBox(width: 8),
              Expanded(child: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis, style: sans(12.5, height: 1.45, color: AppColors.fg2))),
              const Padding(padding: EdgeInsets.only(left: 4, top: 1), child: AppIcon('chevron-right', size: 14, color: AppColors.fg4)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Renders an `ask_user` pending question (status waiting_for_input) and sends the
/// answer back as a LoopInput::Answer. Handles free_text / single_choice / yes_no /
/// confirm answer kinds.
class _QuestionBar extends StatefulWidget {
  final Map<String, dynamic> question; // {questions:[...], context}
  final void Function(Map<String, dynamic>) onSend;
  const _QuestionBar({required this.question, required this.onSend});
  @override
  State<_QuestionBar> createState() => _QuestionBarState();
}

class _QuestionBarState extends State<_QuestionBar> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, String> _choice = {};

  List<Map<String, dynamic>> get _questions =>
      ((widget.question['questions'] as List?) ?? const []).cast<Map<String, dynamic>>();

  String _kind(Map<String, dynamic> q) =>
      (q['answer_kind'] is Map ? q['answer_kind']['kind'] : null)?.toString() ?? 'free_text';

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ready => _questions.every((q) {
        final id = q['id'].toString();
        return _kind(q) == 'free_text'
            ? (_text[id]?.text.trim().isNotEmpty ?? false)
            : (_choice[id]?.isNotEmpty ?? false);
      });

  void _submit() {
    if (!_ready) return;
    final multi = _questions.length > 1;
    final parts = _questions.map((q) {
      final id = q['id'].toString();
      final a = _kind(q) == 'free_text' ? (_text[id]?.text.trim() ?? '') : (_choice[id] ?? '');
      return multi ? '${q['text']}\n→ $a' : a;
    }).toList();
    widget.onSend({'kind': 'answer', 'value': parts.join('\n\n')});
  }

  Widget _chip(String label, bool sel, VoidCallback onTap) => Material(
        color: sel ? AppColors.accent : AppColors.surface2,
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(99),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(label, style: sans(12.5, weight: FontWeight.w500, color: sel ? AppColors.accentFg : AppColors.fg1)),
          ),
        ),
      );

  // Full-width selectable row for single-choice options (labels are sentences).
  Widget _choiceRow(String label, bool sel, VoidCallback onTap) => Material(
        color: sel ? AppColors.accent : AppColors.surface2,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(children: [
              Expanded(child: Text(label, style: sans(12.5, height: 1.35, weight: FontWeight.w500, color: sel ? AppColors.accentFg : AppColors.fg1))),
              if (sel) ...[const SizedBox(width: 8), const AppIcon('check', size: 15, color: AppColors.accentFg)],
            ]),
          ),
        ),
      );

  List<Widget> _inputFor(Map<String, dynamic> q) {
    final id = q['id'].toString();
    final k = _kind(q);
    if (k == 'yes_no' || k == 'confirm') {
      final opts = k == 'confirm' ? const ['Confirm', 'Cancel'] : const ['Yes', 'No'];
      final vals = k == 'confirm' ? const ['confirm', 'cancel'] : const ['yes', 'no'];
      return [
        Wrap(spacing: 8, children: [
          for (var i = 0; i < opts.length; i++)
            _chip(opts[i], _choice[id] == vals[i], () => setState(() => _choice[id] = vals[i])),
        ]),
      ];
    }
    if (k == 'single_choice') {
      // Each choice is {value, label}; show the label, send the value (matches the
      // TUI). Falling back keeps it robust if one side is missing.
      final choices = ((q['answer_kind']?['choices'] as List?) ?? const []).map((e) {
        if (e is Map) {
          final label = '${e['label'] ?? ''}'.trim();
          final value = '${e['value'] ?? ''}'.trim();
          final v = value.isEmpty ? label : value;
          return (value: v, label: label.isEmpty ? v : label);
        }
        final s = '$e';
        return (value: s, label: s);
      }).toList();
      return [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in choices)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _choiceRow(c.label, _choice[id] == c.value, () => setState(() => _choice[id] = c.value)),
            ),
        ]),
      ];
    }
    _text.putIfAbsent(id, () => TextEditingController());
    return [
      AppField(controller: _text[id]!, hint: 'Your answer', maxLines: 4, onSubmitted: (_) => _submit()),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.question['context']?.toString();
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: AppColors.accentBg, border: Border.all(color: AppColors.accentLine), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: AppIcon('alert-triangle', size: 16, color: AppColors.accent)),
          const SizedBox(width: 9),
          Expanded(child: Text('The agent needs your input', style: sans(13, weight: FontWeight.w600, color: AppColors.fg1))),
        ]),
        if (ctx != null && ctx.isNotEmpty && ctx != 'null') ...[
          const SizedBox(height: 8),
          Text(ctx, style: sans(12.5, height: 1.4, color: AppColors.fg2)),
        ],
        for (final q in _questions) ...[
          const SizedBox(height: 12),
          Text(q['text']?.toString() ?? '', style: sans(13, weight: FontWeight.w500, height: 1.35, color: AppColors.fg1)),
          const SizedBox(height: 8),
          ..._inputFor(q),
        ],
        const SizedBox(height: 12),
        Btn('Send answer', small: true, icon: 'send', full: true, disabled: !_ready, onTap: _ready ? _submit : null),
      ]),
    );
  }
}

/// Inline circular send button for the composer.
class _SendBtn extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;
  const _SendBtn({required this.enabled, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? AppColors.accent : AppColors.surface3,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Center(child: AppIcon('send', size: 16, color: enabled ? AppColors.accentFg : AppColors.fg4)),
        ),
      ),
    );
  }
}
