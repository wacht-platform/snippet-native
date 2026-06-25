import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

class SessionScreen extends StatefulWidget {
  final DaemonClient client;
  final String sessionId;
  final String title;
  const SessionScreen({super.key, required this.client, required this.sessionId, required this.title});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  WebSocketChannel? _channel;
  HarnessState? _state;
  String? _connError;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _connect();
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
          setState(() => _state = HarnessState.fromJson(j));
          WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
        } catch (_) {}
      },
      onError: (e) => mounted ? setState(() => _connError = '$e') : null,
      onDone: () => mounted ? setState(() => _connError = 'Lost connection') : null,
    );
  }

  void _toBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _send(Map<String, dynamic> m) => _channel?.sink.add(jsonEncode(m));

  void _sendMessage() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    _send({'kind': 'user_message', 'value': t});
    _input.clear();
    setState(() {});
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  void dispose() {
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
        child: Column(children: [
          SnAppBar(
            title: widget.title.isEmpty ? 'session' : widget.title,
            subtitle: s != null && s.workspace.isNotEmpty ? s.workspace : null,
            onBack: () => Navigator.pop(context),
            actions: [if (running) IconBtn('stop', tooltip: 'Stop', onTap: () => _send({'kind': 'interrupt'})), _menu(s)],
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
                      if (waiting && _pendingApproval(events)) ...[const SizedBox(height: 12), _ApprovalBar(onSend: _send)],
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
        item('model', 'cpu', 'Switch model'),
        item('compact', 'minimize', 'Compact history'),
        item('mode', 'shield', 'Approval mode', value: approval),
        const PopupMenuDivider(height: 8),
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
    if (s != null) {
      if (s.contextWindow > 0 && s.lastPromptTokens > 0) {
        chips.add(_StatMeta(icon: 'activity', label: '${(s.lastPromptTokens / s.contextWindow * 100).clamp(0, 999).round()}% ctx'));
      }
      if (s.totalTokens > 0) chips.add(_StatMeta(icon: 'zap', label: '${fmtSi(s.totalTokens)} tok'));
      chips.add(_StatMeta(icon: 'shield', label: s.approvalMode == 'auto' ? 'Auto-approve' : 'Ask', tone: s.approvalMode == 'auto' ? 'accent' : 'default'));
      final rp = s.ratePrimary;
      if (rp != null) chips.add(_StatMeta(icon: 'clipboard', label: '${rateWindowLabel(rp.windowMinutes)} · ${rp.leftPercent.round()}%', tone: 'run'));
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
    return Container(
      padding: EdgeInsets.fromLTRB(12, 10, 12, 12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
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
        if (running)
          _SquareBtn(icon: 'stop', bg: AppColors.dangerBg, fg: AppColors.danger, border: AppColors.danger.withValues(alpha: 0.3), onTap: () => _send({'kind': 'interrupt'}))
        else
          _SquareBtn(icon: 'send', bg: hasText ? AppColors.accent : AppColors.surface2, fg: hasText ? AppColors.accentFg : AppColors.fg4, onTap: hasText ? _sendMessage : null),
      ]),
    );
  }

  // ---- event → widget (pairs tool_call with its tool_result) ----
  List<Widget> _transcript(List<Map<String, dynamic>> events) {
    final out = <Widget>[];
    Map<String, dynamic>? pending;
    void flush() {
      if (pending != null) {
        out.add(ToolLine(tool: _s(pending!['tool_name']), arg: _short(pending!['arguments'])));
        pending = null;
      }
    }

    for (final e in events) {
      final k = e['kind'] as String? ?? '';
      switch (k) {
        case 'tool_call':
          flush();
          pending = e;
        case 'tool_result':
          if (pending != null) {
            out.add(ToolLine(tool: _s(pending!['tool_name']), arg: _short(pending!['arguments']), out: _resultStatus(e['result'])));
            pending = null;
          } else {
            out.add(ToolLine(tool: _s(e['tool_name']), out: _resultStatus(e['result'])));
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
          out.add(NoteLine(_s(e['entry'])));
        case 'system_decision':
          flush();
          out.add(NoteLine(_s(e['reasoning'])));
        case 'lane_spawned':
          flush();
          out.add(NoteLine('lane: ${_s(e['title'])}'));
        case 'lane_completed':
          flush();
          out.add(NoteLine('lane done: ${_s(e['title'])}'));
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
  String _short(dynamic v) {
    if (v == null) return '';
    if (v is Map) {
      for (final key in ['command', 'path', 'query', 'file']) {
        if (v[key] is String) return v[key] as String;
      }
    }
    final s = v is String ? v : jsonEncode(v);
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  String _resultStatus(dynamic r) => (r is Map && r['status'] != null) ? r['status'].toString() : 'done';

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
      if (mounted) setState(_connect);
    } catch (e) {
      _toast('$e');
    }
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
      if (s.ratePrimary != null || s.rateSecondary != null) ...[
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

class _SquareBtn extends StatelessWidget {
  final String icon;
  final Color bg, fg;
  final Color? border;
  final VoidCallback? onTap;
  const _SquareBtn({required this.icon, required this.bg, required this.fg, this.border, this.onTap});
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
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: border != null ? Border.all(color: border!) : null),
          child: Icon(iconFor(icon), size: icon == 'send' ? 18 : 16, color: fg),
        ),
      ),
    );
  }
}
