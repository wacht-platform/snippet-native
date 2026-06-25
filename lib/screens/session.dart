import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../theme.dart';
import '../models.dart';

/// Attaches to a session over WebSocket: receives HarnessState frames and renders
/// the transcript, and sends user messages / approvals / interrupt.
class SessionScreen extends StatefulWidget {
  final DaemonClient client;
  final String sessionId;
  final String title;
  const SessionScreen({
    super.key,
    required this.client,
    required this.sessionId,
    required this.title,
  });

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
      onError: (e) {
        if (mounted) setState(() => _connError = '$e');
      },
      onDone: () {
        if (mounted) setState(() => _connError = 'Disconnected.');
      },
    );
  }

  void _toBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _send(Map<String, dynamic> input) =>
      _channel?.sink.add(jsonEncode(input));

  void _sendMessage() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    _send({'kind': 'user_message', 'value': t});
    _input.clear();
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
    final state = _state;
    final status = state?.status ?? 'connecting';
    final running = status == 'running';
    final waiting = status == 'waiting_for_input';
    final events = state?.events ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? 'session' : widget.title,
            overflow: TextOverflow.ellipsis),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 16, bottom: 6),
            child: Row(
              children: [
                GlowDot(
                  color: running
                      ? AppColors.running
                      : (status == 'connecting' || _connError != null
                          ? AppColors.muted
                          : AppColors.online),
                  size: 8,
                ),
                const SizedBox(width: 8),
                Text(
                  status +
                      (state != null && state.totalTokens > 0
                          ? '  ·  ${state.totalTokens} tok'
                          : ''),
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (running)
            IconButton(
              tooltip: 'Stop',
              onPressed: () => _send({'kind': 'interrupt'}),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_connError != null)
            Material(
              color: AppColors.offline.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_connError!,
                          style: const TextStyle(color: AppColors.offline)),
                    ),
                    TextButton(
                        onPressed: () => setState(_connect),
                        child: const Text('Reconnect')),
                  ],
                ),
              ),
            ),
          Expanded(
            child: state == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    itemCount: events.length,
                    itemBuilder: (_, i) => _EventTile(events[i]),
                  ),
          ),
          if (waiting && _pendingApproval(events)) _ApprovalBar(onSend: _send),
          _inputBar(running),
        ],
      ),
    );
  }

  Widget _inputBar(bool running) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 10),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: InputDecoration(
                  hintText: running ? 'Queue a message…' : 'Message…',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sendMessage,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: AppColors.accentGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.arrow_upward,
                    color: Color(0xFF0A0D13), size: 22),
              ),
            ),
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: AppColors.surfaceAlt,
      child: Row(
        children: [
          const Expanded(
            child: Text('Approve this action?',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          TextButton(
              onPressed: () => onSend({'kind': 'deny'}),
              child: const Text('Deny',
                  style: TextStyle(color: AppColors.offline))),
          TextButton(
              onPressed: () => onSend({'kind': 'approve_all'}),
              child: const Text('All')),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: () => onSend({'kind': 'approve'}),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
  }
}

/// Renders one HarnessEvent by its `kind`. Defensive: missing fields render empty.
class _EventTile extends StatelessWidget {
  final Map<String, dynamic> e;
  const _EventTile(this.e);

  @override
  Widget build(BuildContext context) {
    final kind = e['kind'] as String? ?? '';
    switch (kind) {
      case 'user_input':
      case 'steer':
        return _bubble(context, _str(e['text']),
            mine: true);
      case 'assistant_text':
        return _bubble(context, _str(e['text']), mine: false);
      case 'note':
        return _line('📝 ${_str(e['entry'])}', AppColors.muted);
      case 'tool_call':
        return _line('🔧 ${_str(e['tool_name'])}  ${_short(e['arguments'])}',
            AppColors.accent);
      case 'tool_result':
        return _line('↳ ${_str(e['tool_name'])} · ${_resultStatus(e['result'])}',
            AppColors.muted);
      case 'system_decision':
        return _line('• ${_str(e['step'])}: ${_str(e['reasoning'])}',
            AppColors.muted);
      case 'model_error':
        return _line('⚠ ${_str(e['message'])}', AppColors.offline);
      case 'invalid_tool_call':
        return _line('⚠ invalid ${_str(e['tool_name'])}: ${_str(e['error'])}',
            AppColors.offline);
      case 'lane_spawned':
        return _line('⑃ lane: ${_str(e['title'])}', AppColors.muted);
      case 'lane_completed':
        return _line(
            '⑃ lane done: ${_str(e['title'])} (${_str(e['status'])})',
            AppColors.muted);
      case 'approval_request':
        return _line(
            '⏸ approval: ${_str(e['tool_name'])} — ${_str(e['summary'])}',
            AppColors.running);
      case 'user_question':
        return _line('❓ ${_short(e['questions'])}', AppColors.running);
      default:
        return const SizedBox.shrink();
    }
  }

  String _str(dynamic v) => v == null ? '' : v.toString();

  String _short(dynamic v) {
    if (v == null) return '';
    final s = v is String ? v : jsonEncode(v);
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  String _resultStatus(dynamic r) =>
      (r is Map && r['status'] != null) ? r['status'].toString() : 'done';

  Widget _bubble(BuildContext c, String text, {required bool mine}) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(c).size.width * 0.82),
        decoration: BoxDecoration(
          color: mine
              ? AppColors.accent.withValues(alpha: 0.18)
              : AppColors.surface,
          border: Border.all(
              color: mine
                  ? AppColors.accent.withValues(alpha: 0.35)
                  : AppColors.border),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: SelectableText(text,
            style: const TextStyle(color: AppColors.text, fontSize: 14.5, height: 1.35)),
      ),
    );
  }

  Widget _line(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        text,
        style: TextStyle(
            fontFamily: 'monospace', fontSize: 12.5, color: color),
      ),
    );
  }
}
