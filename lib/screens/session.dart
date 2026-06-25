import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
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
        } catch (_) {
          // ignore frames that aren't HarnessState JSON
        }
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

  void _send(Map<String, dynamic> input) => _channel?.sink.add(jsonEncode(input));

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
        title: Text(
          widget.title.isEmpty ? 'session' : widget.title,
          overflow: TextOverflow.ellipsis,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: Text(
              status +
                  (state != null && state.totalTokens > 0
                      ? '  ·  ${state.totalTokens} tok'
                      : ''),
              style: Theme.of(context).textTheme.bodySmall,
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
            MaterialBanner(
              content: Text(_connError!),
              actions: [
                TextButton(
                  onPressed: () => setState(_connect),
                  child: const Text('Reconnect'),
                ),
              ],
            ),
          Expanded(
            child: state == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
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
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            IconButton(onPressed: _sendMessage, icon: const Icon(Icons.send)),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const Expanded(child: Text('Approve this action?')),
          TextButton(
            onPressed: () => onSend({'kind': 'deny'}),
            child: const Text('Deny'),
          ),
          TextButton(
            onPressed: () => onSend({'kind': 'approve_all'}),
            child: const Text('All'),
          ),
          FilledButton(
            onPressed: () => onSend({'kind': 'approve'}),
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
    final scheme = Theme.of(context).colorScheme;
    switch (kind) {
      case 'user_input':
      case 'steer':
        return _bubble(context, _str(e['text']),
            align: Alignment.centerRight, color: scheme.primaryContainer);
      case 'assistant_text':
        return _bubble(context, _str(e['text']),
            align: Alignment.centerLeft, color: scheme.surfaceContainerHighest);
      case 'note':
        return _line(context, '📝 ${_str(e['entry'])}', dim: true);
      case 'tool_call':
        return _line(context, '🔧 ${_str(e['tool_name'])}  ${_short(e['arguments'])}');
      case 'tool_result':
        return _line(context, '↳ ${_str(e['tool_name'])} · ${_resultStatus(e['result'])}',
            dim: true);
      case 'system_decision':
        return _line(context, '• ${_str(e['step'])}: ${_str(e['reasoning'])}', dim: true);
      case 'model_error':
        return _line(context, '⚠ ${_str(e['message'])}', color: scheme.error);
      case 'invalid_tool_call':
        return _line(context, '⚠ invalid ${_str(e['tool_name'])}: ${_str(e['error'])}',
            color: scheme.error);
      case 'lane_spawned':
        return _line(context, '⑃ lane: ${_str(e['title'])}', dim: true);
      case 'lane_completed':
        return _line(context, '⑃ lane done: ${_str(e['title'])} (${_str(e['status'])})',
            dim: true);
      case 'approval_request':
        return _line(context, '⏸ approval: ${_str(e['tool_name'])} — ${_str(e['summary'])}');
      case 'user_question':
        return _line(context, '❓ ${_short(e['questions'])}');
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

  Widget _bubble(BuildContext c, String text,
      {required Alignment align, required Color color}) {
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(c).size.width * 0.82),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: SelectableText(text),
      ),
    );
  }

  Widget _line(BuildContext c, String text, {bool dim = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          color: color ?? (dim ? Theme.of(c).hintColor : null),
        ),
      ),
    );
  }
}
