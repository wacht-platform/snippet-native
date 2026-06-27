import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../models.dart';
import '../notifications.dart';
import '../theme.dart';
import '../tool_views.dart';
import '../widgets.dart';

class SessionScreen extends StatefulWidget {
  final DaemonClient client;
  final String sessionId;
  final String title;
  final String? profile;
  const SessionScreen({super.key, required this.client, required this.sessionId, required this.title, this.profile});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
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
  // A pending image attachment: local path for the thumbnail + the uploaded
  // daemon path the agent will read_image. _uploading while the upload is in flight.
  String? _localImagePath;
  String? _pendingImagePath;
  bool _uploading = false;
  bool _didInitialScroll = false;

  @override
  void initState() {
    super.initState();
    _connect();
    _loadModel();
    reportOpenSession('${widget.client.baseUrl}|${widget.sessionId}');
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
    _channel?.sink.close();
    _connError = null;
    final ch = widget.client.attach(widget.sessionId);
    _channel = ch;
    ch.stream.listen(
      (msg) {
        try {
          final j = jsonDecode(msg as String) as Map<String, dynamic>;
          if (!mounted) return;
          final cur = _state;
          final next = (j['wire'] == 'delta' && cur != null) ? cur.applyDelta(j) : HarnessState.fromJson(j);
          final firstLoad = !_didInitialScroll && next.events.isNotEmpty;
          setState(() {
            _state = next;
            _reconcileQueued(next.events);
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (firstLoad) {
              _didInitialScroll = true;
              // Jump to the bottom on open; re-jump to catch late layout growth
              // (markdown/code blocks measure after the first frame).
              _toBottom(jump: true);
              Future.delayed(const Duration(milliseconds: 120), () { if (mounted) _toBottom(jump: true); });
              Future.delayed(const Duration(milliseconds: 350), () { if (mounted) _toBottom(jump: true); });
            } else {
              _toBottom();
            }
          });
        } catch (_) {}
      },
      onError: (e) => mounted ? setState(() => _connError = '$e') : null,
      onDone: () => mounted ? setState(() => _connError = 'Lost connection') : null,
    );
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
    _send({'kind': 'user_message', 'value': msg});
    _input.clear();
    // While running, show it on-screen as a queued bubble instead of a toast.
    setState(() {
      if (running) _queued.add(t.isEmpty ? '🖼 image' : t);
      _localImagePath = null;
      _pendingImagePath = null;
      _uploading = false;
    });
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
  void _cancelQueued() {
    _send({'kind': 'drop_queued'});
    setState(() => _queued.clear());
  }

  // Drop queued items that the daemon has now applied (they arrive as `steer`
  // events). FIFO match so duplicate texts reconcile in order.
  void _reconcileQueued(List<Map<String, dynamic>> events) {
    if (_queued.isEmpty) return;
    final applied = <String>[];
    for (final e in events) {
      if (e['kind'] == 'steer') applied.add(e['text']?.toString() ?? '');
    }
    final remaining = <String>[];
    for (final q in _queued) {
      final i = applied.indexOf(q);
      if (i >= 0) {
        applied.removeAt(i);
      } else {
        remaining.add(q);
      }
    }
    _queued
      ..clear()
      ..addAll(remaining);
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  void dispose() {
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
            title: widget.title.isEmpty ? 'session' : widget.title,
            subtitle: s != null && s.workspace.isNotEmpty ? s.workspace : null,
            onBack: () => Navigator.pop(context),
            actions: [
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
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                    children: [
                      if (items.isEmpty && !running)
                        const EmptyState(icon: 'terminal', title: 'Session ready', body: 'Send a task to get started.'),
                      ...items,
                      if (running) ...[const SizedBox(height: 12), const _TypingDots()],
                      if (_queued.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        for (final q in _queued) _QueuedBubble(text: q, onCancel: _cancelQueued),
                      ],
                      if (waiting && _pendingApproval(events)) ...[const SizedBox(height: 12), _ApprovalBar(onSend: _send)]
                      else if (waiting && s.pendingQuestion != null) ...[const SizedBox(height: 12), _QuestionBar(question: s.pendingQuestion!, onSend: _send)],
                    ],
                  ),
          ),
          _inputBar(running),
        ]),
      ),
    );
  }

  Widget _menu(HarnessState? s) {
    final approval = (s?.approvalMode ?? 'auto') == 'auto' ? 'Auto' : 'Ask';
    PopupMenuItem<String> item(String v, String icon, String label, {String? value, bool divider = false}) {
      return PopupMenuItem<String>(
        value: v,
        height: 40,
        child: Row(children: [
          AppIcon(icon, size: 16, color: AppColors.fg2),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: sans(13, color: AppColors.fg1))),
          if (value != null) Text(value, style: mono(11.5, color: AppColors.fg3)),
        ]),
      );
    }

    return PopupMenuButton<String>(
      color: AppColors.surface2,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: const BorderSide(color: AppColors.border2)),
      icon: const AppIcon('more-vertical', color: AppColors.fg2),
      onSelected: (v) {
        switch (v) {
          case 'model':
            _switchModel();
          case 'compact':
            _send({'kind': 'compact'});
            _toast('Compacting history');
          case 'exec':
            _showExec();
          case 'mode':
            final manual = (s?.approvalMode ?? 'auto') == 'manual';
            _send({'kind': 'set_mode', 'value': manual ? 'auto' : 'manual'});
            _toast(manual ? 'Approval: auto' : 'Approval: ask');
          case 'usage':
            _showUsage();
          case 'checkpoints':
            _showCheckpoints();
        }
      },
      itemBuilder: (_) => [
        item('model', 'cpu', 'Switch model', value: _modelLabel),
        item('compact', 'minimize', 'Compact history'),
        item('exec', 'terminal', 'Run command'),
        item('mode', 'shield', 'Approval mode', value: approval),
        item('usage', 'activity', 'Usage'),
        item('checkpoints', 'history', 'Checkpoints'),
      ],
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
          onTap: () => setState(_connect),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const AppIcon('refresh', size: 13, color: AppColors.danger),
            const SizedBox(width: 5),
            Text('Reconnect', style: sans(12, weight: FontWeight.w600, color: AppColors.danger)),
          ]),
        ),
      ]),
    );
  }

  Widget _inputBar(bool running) {
    final hasText = _input.text.trim().isNotEmpty;
    final canSend = (hasText || _pendingImagePath != null) && !_uploading;
    return Container(
      padding: EdgeInsets.fromLTRB(12, 10, 12, 12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_localImagePath != null) _imageChip(),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          _SquareBtn(icon: 'image', bg: AppColors.surface2, fg: _uploading ? AppColors.fg4 : AppColors.fg2, onTap: _uploading ? null : _attachImage),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: AppColors.surface2, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(18)),
              padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                cursorColor: AppColors.accent,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _sendMessage(),
                style: sans(13.5, height: 1.45, color: AppColors.fg1),
                decoration: InputDecoration(
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  border: InputBorder.none,
                  hintText: 'Message snippet…',
                  hintStyle: sans(13.5, color: AppColors.fg4),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SquareBtn(icon: 'send', bg: canSend ? AppColors.accent : AppColors.surface2, fg: canSend ? AppColors.accentFg : AppColors.fg4, onTap: canSend ? _sendMessage : null),
        ]),
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
    void flush() {
      final p = pending;
      if (p != null) {
        final name = _s(p['tool_name']);
        out.add(ToolLine(tool: name, icon: toolIcon(name), arg: toolArgSummary(name, p['arguments']), done: false, onTap: () => _showToolDetail(name, p['arguments'], null)));
        pending = null;
      }
    }

    for (final e in events) {
      final k = e['kind'] as String? ?? '';
      switch (k) {
        case 'tool_call':
          flush();
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
              out.add(ToolLine(tool: name, icon: toolIcon(name), arg: toolArgSummary(name, p['arguments']), out: _resultStatus(e['result']), done: _ok(e['result']), onTap: () => _showToolDetail(name, p['arguments'], e['result'])));
              pending = null;
            } else {
              final name = _s(e['tool_name']);
              if (_isMetaTool(name)) break;
              out.add(ToolLine(tool: name, icon: toolIcon(name), out: _resultStatus(e['result']), done: _ok(e['result']), onTap: () => _showToolDetail(name, null, e['result'])));
            }
          }
        case 'user_input':
        case 'steer':
          flush();
          out.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: Bubble(mine: true, text: _s(e['text']))));
        case 'assistant_text':
          flush();
          out.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: Bubble(mine: false, text: _s(e['text']))));
        case 'model_error':
          flush();
          out.add(NoteLine(_s(e['message']), error: true));
        case 'invalid_tool_call':
          flush();
          out.add(NoteLine('invalid ${_s(e['tool_name'])}: ${_s(e['error'])}', error: true));
        case 'note':
          flush();
          final entry = _s(e['entry']);
          out.add(_NoteLine(entry, onTap: () => _showNote(entry)));
        case 'system_decision':
          flush();
          out.add(NoteLine(_s(e['reasoning'])));
        case 'lane_spawned':
          flush();
          out.add(NoteLine('lane: ${_s(e['title'])}'));
        case 'lane_completed':
          flush();
          out.add(NoteLine('lane done: ${_s(e['title'])}'));
        case 'user_question':
          flush();
          final qd = e['questions'];
          final qs = (qd is Map ? qd['questions'] : null) as List?;
          final txt = (qs != null && qs.isNotEmpty && qs.first is Map) ? _s((qs.first as Map)['text']) : '';
          if (txt.isNotEmpty) out.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: Bubble(mine: false, text: '❓ $txt')));
        case 'approval_request':
          break; // shown by the approval bar
        default:
          break;
      }
    }
    flush();
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

  void _showToolDetail(String name, dynamic args, dynamic result) {
    showAppSheet(context,
        title: toolTitle(name),
        child: toolDetailView(context, tool: name, args: args, result: result));
  }

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
class _QueuedBubble extends StatelessWidget {
  final String text;
  final VoidCallback onCancel;
  const _QueuedBubble({required this.text, required this.onCancel});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          padding: const EdgeInsets.fromLTRB(13, 9, 7, 9),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(color: AppColors.border2, style: BorderStyle.solid),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomRight: Radius.circular(5),
              bottomLeft: Radius.circular(16),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 2, right: 7), child: AppIcon('history', size: 12, color: AppColors.fg3)),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Queued', style: sans(10, weight: FontWeight.w500, color: AppColors.fg3)),
                const SizedBox(height: 2),
                Text(text, style: sans(13.5, height: 1.4, color: AppColors.fg2)),
              ]),
            ),
            IconBtn('x', size: 28, iconSize: 15, tooltip: 'Cancel', onTap: onCancel),
          ]),
        ),
      ),
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
      final choices = ((q['answer_kind']?['choices'] as List?) ?? const []).map((e) => e.toString()).toList();
      return [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in choices) _chip(c, _choice[id] == c, () => setState(() => _choice[id] = c)),
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

class _SquareBtn extends StatelessWidget {
  final String icon;
  final Color bg, fg;
  final VoidCallback? onTap;
  const _SquareBtn({required this.icon, required this.bg, required this.fg, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
          child: Icon(iconFor(icon), size: icon == 'send' ? 18 : 16, color: fg),
        ),
      ),
    );
  }
}
