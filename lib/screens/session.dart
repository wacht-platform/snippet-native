import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../models.dart';
import '../notifications.dart';
import '../platform.dart';
import '../theme.dart';
import '../transcript.dart';
import '../panel.dart';
import '../widgets.dart';
import 'editor.dart';
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
  /// When embedded in a narrow desktop shell, opens the collapsed sidebar drawer.
  final VoidCallback? onMenu;
  /// When set, opening a file from the Files browser opens it as a shell tab
  /// instead of pushing an editor route.
  final void Function(String path, String name)? onOpenFileTab;
  const SessionScreen({super.key, required this.client, required this.sessionId, required this.title, this.profile, this.embedded = false, this.onMenu, this.onOpenFileTab});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> with WidgetsBindingObserver {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  // Outbound payloads queued while the socket is down; flushed in order on the
  // next healthy frame (silently dropping sends lost user messages/approvals).
  final List<String> _outbox = [];
  // The open-session suppression key THIS screen registered. Session switches
  // mount the new screen before disposing the old one, so dispose must only
  // clear the registration if it still owns it.
  static String _registeredOpenKey = '';
  late final String _openKey;
  HarnessState? _state;
  String? _connError;
  String? _modelLabel;
  String? _currentProfile;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  // Messages sent mid-run, shown optimistically until the daemon applies them as
  // a `steer` event (then reconciled away). Cancelled via the drop_queued input.
  final List<String> _queued = [];
  // Messages sent to the daemon but not yet echoed back as events — shown
  // optimistically (faint) so they don't vanish during the round-trip.
  final List<String> _pending = [];

  // How many user turns (typed or steered) the daemon has echoed into the event
  // log — the FIFO baseline for retiring optimistic bubbles (see the socket
  // handler; count-based, not text-based, so daemon-side trimming can't strand one).
  static int _userEchoCount(List<Map<String, dynamic>> events) =>
      events.where((e) => e['kind'] == 'user_input' || e['kind'] == 'steer').length;
  // Big-paste interception: a paste arrives as ONE controller change, so an
  // insertion this large can't be typing — pull it out of the field and attach
  // it as a text file instead (through the same _ingest pipeline as any file).
  static const _pasteAttachChars = 1000;
  static const _pasteAttachLines = 15;
  String _lastInput = '';
  bool _restoringInput = false;
  int _pasteN = 0;

  void _interceptBigPaste() {
    if (_restoringInput) return;
    final prev = _lastInput;
    final now = _input.text;
    if (now.length - prev.length < _pasteAttachChars) {
      // Also catch shorter-but-many-line pastes cheaply.
      if (now.length <= prev.length || !now.contains('\n')) {
        _lastInput = now;
        return;
      }
    }
    // Single-change diff: common prefix + suffix bound the inserted span.
    var p = 0;
    while (p < prev.length && p < now.length && prev[p] == now[p]) {
      p++;
    }
    var s = 0;
    while (s < prev.length - p && s < now.length - p && prev[prev.length - 1 - s] == now[now.length - 1 - s]) {
      s++;
    }
    final inserted = now.substring(p, now.length - s);
    final lines = '\n'.allMatches(inserted).length + 1;
    if (inserted.length < _pasteAttachChars && lines < _pasteAttachLines) {
      _lastInput = now;
      return;
    }
    // Restore the field to what it was without the pasted wall, cursor at the seam.
    _restoringInput = true;
    _input.value = TextEditingValue(
      text: prev,
      selection: TextSelection.collapsed(offset: p.clamp(0, prev.length)),
    );
    _restoringInput = false;
    _lastInput = prev;
    final name = 'paste-${++_pasteN}.txt';
    _ingest([(name: name, localPath: null, readBytes: () async => Uint8List.fromList(utf8.encode(inserted)))]);
    _toast('Pasted text attached ($lines lines)');
  }

  // Pending attachments (images + files, up to 10): each uploads to the daemon
  // and is referenced in the next message. Images → read_image, files → read.
  final List<_Attachment> _attachments = [];
  bool get _anyUploading => _attachments.any((a) => a.uploading);
  static const int _maxAttachments = 10;
  bool _dragOver = false; // desktop drag-and-drop highlight
  bool _didInitialScroll = false;
  // Auto-reconnect: backoff timer + attempt counter; _closed stops retries on leave.
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closed = false;
  // A message can silently die on a socket that looks alive (dropped network, no
  // onError/onDone) — it sits in _pending, shown as "sending", forever. Guard:
  // (1) a fresh connection resends anything still unacked against the authoritative
  // snapshot; (2) a watchdog forces a resync if _pending doesn't clear in time.
  bool _freshConn = false;
  Timer? _ackTimer;

  // An approve/deny/answer decision can die on a dead socket exactly like a
  // message — but it isn't in _pending, so the approval bar hangs at "Sending…"
  // forever. Track the last decision until the run leaves waiting_for_input;
  // resend it on reconnect and force a resync if it doesn't resolve.
  Map<String, dynamic>? _pendingDecision;
  Timer? _decisionTimer;

  // Force a fresh snapshot when an optimistic message hasn't been echoed in time —
  // the reconnect path then resends whatever the server truly never received.
  void _armAckWatchdog() {
    _ackTimer?.cancel();
    if (_closed || _pending.isEmpty) return;
    _ackTimer = Timer(const Duration(seconds: 7), () {
      if (!mounted || _closed || _pending.isEmpty) return;
      final ch = _channel;
      if (ch != null) {
        _resync(ch); // tear down → fresh snapshot → unacked _pending resend
      }
    });
  }

  // Send an approve/deny/answer and hold it until the run acknowledges it (leaves
  // waiting_for_input). If it doesn't in time, the decision was lost — resync and
  // resend so the approval bar can't hang at "Sending…".
  void _sendDecision(Map<String, dynamic> m) {
    final k = m['kind'];
    if (k == 'approve' || k == 'approve_all' || k == 'deny' || k == 'answer') {
      _pendingDecision = m;
      _decisionTimer?.cancel();
      _decisionTimer = Timer(const Duration(seconds: 6), () {
        if (!mounted || _closed || _pendingDecision == null) return;
        if (_state?.status == 'waiting_for_input') {
          final ch = _channel;
          if (ch != null) _resync(ch); // fresh snapshot → decision resend below
        }
      });
    }
    _send(m);
  }
  late String _title;
  // Tracks the last status so we can detect running → paused and flush _queued.
  String? _prevStatus;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _lastInput = _input.text;
    _input.addListener(_interceptBigPaste);
    WidgetsBinding.instance.addObserver(this);
    _connect();
    _loadModel();
    _openKey = '${widget.client.baseUrl}|${widget.sessionId}';
    _registeredOpenKey = _openKey;
    reportOpenSession(_openKey);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reconnect on resume ONLY if the socket actually died while backgrounded
    // (_scheduleReconnect nulls _channel). Unconditionally reconnecting tore
    // down a healthy socket and forced a full-snapshot reload + scroll jump
    // after even a momentary backgrounding. If the OS silently killed the
    // socket without an event, the next write fails → onError → reconnect.
    if (state == AppLifecycleState.resumed && !_closed) {
      if (_channel == null) {
        _reconnectAttempt = 0;
        _connect();
        // Re-sync the model label from the daemon after a real reconnect: it may
        // have changed while backgrounded (from the TUI or another device).
        _loadModel();
      }
      // Backgrounding cleared the suppression key (so notifications fire while
      // away); restore it — this session is visible again.
      _registeredOpenKey = _openKey;
      reportOpenSession(_openKey);
    }
  }

  Future<void> _loadModel() async {
    try {
      final cfg = await widget.client.getConfig();

      // Resolve which profile this session is on, most authoritative first:
      //   1. an in-session pick the user just made (optimistic, same screen);
      //   2. the daemon's live per-session override — the source of truth; it's
      //      persisted server-side and survives remount/resume/daemon restart;
      //   3. only if the daemon is unreachable, the value the session list
      //      handed us (which goes stale after a switch — that staleness is
      //      exactly what used to snap the header back to the global default).
      // A session with no override resolves to null → the global active profile
      // below. Reading the server, not the list cache, is what keeps a
      // per-chat model sticky when you leave and come back to the window.
      String? wanted = _currentProfile;
      if (wanted == null) {
        try {
          final list = await widget.client.sessions();
          var found = false;
          for (final s in list) {
            if (s.id == widget.sessionId) {
              wanted = s.profile; // null here means "uses the global default"
              found = true;
              break;
            }
          }
          if (!found) wanted = widget.profile;
        } catch (_) {
          wanted = widget.profile;
        }
      }

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
        });
      }
    } catch (_) {}
  }

  void _connect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    // Fully detach the old socket first: cancel its subscription so its onDone
    // can't fire _scheduleReconnect against the NEW channel — that cascade
    // orphaned healthy sockets and double-applied every delta.
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    if (mounted) setState(() => _connError = null);
    final ch = widget.client.attach(widget.sessionId);
    _channel = ch;
    // The first snapshot on this socket triggers the unacked-message resend.
    _freshConn = true;
    _sub = ch.stream.listen(
      (msg) {
        if (!identical(ch, _channel)) return; // stale socket — ignore
        // Any frame means a healthy socket — reset backoff + clear the banner.
        if (_reconnectAttempt != 0 || _connError != null) {
          _reconnectAttempt = 0;
          if (mounted) setState(() => _connError = null);
        }
        // Flush sends queued while the socket was down, in order.
        if (_outbox.isNotEmpty) {
          for (final p in _outbox) {
            ch.sink.add(p);
          }
          _outbox.clear();
        }
        try {
          final j = jsonDecode(msg as String) as Map<String, dynamic>;
          if (!mounted) return;
          final cur = _state;
          final next = (j['wire'] == 'delta' && cur != null) ? cur.applyDelta(j) : HarnessState.fromJson(j);
          // Drift check: our event log must line up with the server's count — a
          // mismatch (dropped/bad frame) resyncs via reconnect, since a fresh
          // socket's first frame is always a full snapshot.
          final ec = j['event_count'];
          if (j['wire'] == 'delta' && ec is int && next.events.length != ec) {
            _resync(ch);
            return;
          }
          final firstLoad = !_didInitialScroll && next.events.isNotEmpty;
          // Auto-follow while pinned to the bottom; the user scrolling up turns it
          // off (and back on when they return) — content growth never does.
          final follow = _stickToBottom;
          // Auto-submit queued messages only when the run lands on IDLE. Flushing
          // on any running→non-running edge also fired into waiting_for_input,
          // where the queued text would "answer" the agent's own question. So
          // flush on ANY running→not-running edge EXCEPT waiting_for_input —
          // that covers idle (finished) AND interrupted (user paused/stopped the
          // run), which previously left the queue stranded.
          // Sent as a BURST of individual messages: the first opens the turn and
          // the rest fold in as steers before the first model call — the agent
          // sees the full set up front, while each message keeps its own frame
          // (and its own attachments) instead of being joined into one blob.
          if (_prevStatus == 'running' &&
              next.status != 'running' &&
              next.status != 'waiting_for_input' &&
              _queued.isNotEmpty) {
            for (final m in _queued) {
              _send({'kind': 'user_message', 'value': m});
              _pending.add(m);
            }
            _queued.clear();
          }
          _prevStatus = next.status;
          // A pending approval/answer is acknowledged the moment the run leaves
          // waiting_for_input — clear it so its watchdog can't fire a needless
          // resync (and so a resent decision isn't double-applied).
          if (next.status != 'waiting_for_input' && _pendingDecision != null) {
            _pendingDecision = null;
            _decisionTimer?.cancel();
          }
          // Retire optimistic bubbles as the daemon echoes user turns back —
          // FIFO by COUNT of user_input/steer events, not by exact text (the
          // daemon trims/normalizes, so text equality left stuck/dup bubbles).
          // On a full snapshot, reconcile against the previous event log rather
          // than blanket-clearing: a clear here erased just-sent messages that
          // were flushed from the outbox but not yet echoed (they "vanished").
          final prevEchoes = cur == null ? null : _userEchoCount(cur.events);
          final nextEchoes = _userEchoCount(next.events);
          if (prevEchoes != null) {
            var retired = (nextEchoes - prevEchoes).clamp(0, _pending.length);
            while (retired-- > 0) {
              _pending.removeAt(0);
            }
          } else if (j['wire'] != 'delta') {
            _pending.clear(); // first-ever snapshot: nothing optimistic predates it
          }
          // First full snapshot after a (re)connect is authoritative: anything
          // still in _pending was never received by the server — resend it so a
          // message lost to a network blip actually recovers instead of hanging
          // as "sending". Reconciliation above already dropped any that DID land.
          if (_freshConn && j['wire'] != 'delta') {
            _freshConn = false;
            for (final m in _pending) {
              try {
                ch.sink.add(jsonEncode({'kind': 'user_message', 'value': m}));
              } catch (_) {
                _outbox.add(jsonEncode({'kind': 'user_message', 'value': m}));
              }
            }
            // A decision still pending while the snapshot STILL shows the run
            // waiting means it never landed — resend it. (If it had landed, the
            // status/clear above already dropped it, so no double-approve.)
            if (_pendingDecision != null && next.status == 'waiting_for_input') {
              final payload = jsonEncode(_pendingDecision);
              try {
                ch.sink.add(payload);
              } catch (_) {
                _outbox.add(payload);
              }
            }
          }
          setState(() {
            _state = next;
          });
          // Re-arm (or cancel) the ack watchdog against the new _pending state.
          _armAckWatchdog();
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
        } catch (_) {
          // A frame we couldn't apply would silently corrupt the transcript —
          // resync instead of swallowing it.
          _resync(ch);
        }
      },
      onError: (_) => _scheduleReconnect(ch),
      onDone: () => _scheduleReconnect(ch),
      cancelOnError: true,
    );
  }

  // Tear down this socket and rejoin — the fresh connection opens with a full
  // snapshot, which reconciles any local drift.
  void _resync(WebSocketChannel ch) {
    if (!identical(ch, _channel)) return;
    ch.sink.close();
    _scheduleReconnect(ch);
  }

  // Reconnect with exponential backoff (1,2,4,8,15,30s). Deduped so onError+onDone
  // don't double-schedule; reset to 0 on any healthy frame or app-resume. Only the
  // CURRENT channel may schedule — a detached socket's late onDone is ignored.
  void _scheduleReconnect(WebSocketChannel ch) {
    if (_closed) return;
    if (!identical(ch, _channel)) return; // stale socket
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
    final was = _stickToBottom;
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      _stickToBottom = _atBottom();
    } else if (n is ScrollEndNotification) {
      _stickToBottom = _atBottom();
    }
    // Repaint only on the pinned/unpinned EDGE — it toggles the floating
    // "jump to latest" button over the transcript.
    if (was != _stickToBottom && mounted) setState(() {});
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

  // Send now, or queue for the reconnect flush — never silently drop.
  void _send(Map<String, dynamic> m) {
    final payload = jsonEncode(m);
    final ch = _channel;
    if (ch == null) {
      _outbox.add(payload);
      return;
    }
    try {
      ch.sink.add(payload);
    } catch (_) {
      // Sink rejected it though the socket looked alive — queue for the next
      // healthy connection rather than dropping the message.
      _outbox.add(payload);
      _scheduleReconnect(ch);
    }
  }

  void _sendMessage() {
    // An upload still in flight would be silently DROPPED (only remotePath'd
    // attachments ship, then the list is cleared). The send button disables via
    // canSend, but keyboard submit bypassed it — guard here, the single choke point.
    if (_anyUploading) return;
    final t = _input.text.trim();
    final ready = _attachments.where((a) => a.remotePath != null).toList();
    if (t.isEmpty && ready.isEmpty) return;
    final running = _state?.status == 'running';
    // Reference each upload by its exact path so the agent reads it this turn.
    final markers = ready
        .map((a) => a.isImage
            ? '[attached image — call read_image on this exact path to view it: ${a.remotePath}]'
            : '[attached file — read it at this exact path: ${a.remotePath}]')
        .join('\n');
    final msg = markers.isEmpty ? t : (t.isEmpty ? markers : '$t\n\n$markers');
    setState(() {
      if (running) {
        // Busy: hold it and auto-submit when the run pauses (don't steer mid-task).
        _queued.add(msg);
      } else {
        _send({'kind': 'user_message', 'value': msg});
        _pending.add(msg); // show it until the daemon echoes it back
      }
      _attachments.clear();
    });
    _input.clear();
    _armAckWatchdog(); // recover if this send silently dies on a dead socket
    // Sending is an explicit action — re-pin and jump to the bottom.
    _stickToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(jump: true));
  }

  bool _isImageName(String n) {
    final l = n.toLowerCase();
    return const ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'].any(l.endsWith);
  }

  // `+` tapped: desktop opens a file picker directly; mobile shows a small
  // Camera / Photos / Files sheet.
  Future<void> _onAttachTap() async {
    if (_maxAttachments - _attachments.length <= 0) {
      _toast('Up to $_maxAttachments attachments.');
      return;
    }
    if (!kMobile) {
      _pickFiles();
      return;
    }
    final choice = await showAppSheet<String>(context, title: 'Add context', child: Row(children: [
      _ctxOption('camera', 'Camera', 'camera'),
      const SizedBox(width: 10),
      _ctxOption('image', 'Photos', 'photos'),
      const SizedBox(width: 10),
      _ctxOption('file', 'Files', 'files'),
    ]));
    if (choice == 'camera') {
      _pickCamera();
    } else if (choice == 'photos') {
      _pickPhotos();
    } else if (choice == 'files') {
      _pickFiles();
    }
  }

  Widget _ctxOption(String icon, String label, String value) {
    return Expanded(
      child: Material(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(R.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.md),
          onTap: () => Navigator.pop(context, value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(R.md), border: Border.all(color: AppColors.border)),
            child: Column(children: [
              AppIcon(icon, size: 22, color: AppColors.fg2),
              const SizedBox(height: 8),
              Text(label, style: sans(12, color: AppColors.fg1)),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true, type: FileType.any);
    } catch (e) {
      _toast('$e');
      return;
    }
    if (res == null) return;
    await _ingest(res.files
        .map((f) => (
              name: f.name,
              localPath: f.path,
              readBytes: () async => f.bytes ?? await File(f.path!).readAsBytes(),
            ))
        .toList());
  }

  Future<void> _pickPhotos() async {
    final xs = await ImagePicker().pickMultiImage(imageQuality: 85, maxWidth: 2200);
    if (xs.isEmpty) return;
    await _ingest(xs.map((x) => (name: x.name, localPath: x.path, readBytes: x.readAsBytes)).toList());
  }

  Future<void> _pickCamera() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2200);
    if (x == null) return;
    await _ingest([(name: x.name, localPath: x.path, readBytes: x.readAsBytes)]);
  }

  // Create attachment chips for the picked items (capped to 10 total) and upload each.
  Future<void> _ingest(List<({String name, String? localPath, Future<Uint8List> Function() readBytes})> picked) async {
    final remaining = _maxAttachments - _attachments.length;
    if (remaining <= 0) return;
    var items = picked;
    if (items.length > remaining) {
      items = items.take(remaining).toList();
      _toast('Added $remaining (max $_maxAttachments).');
    }
    final entries = items.map((p) => _Attachment(name: p.name, isImage: _isImageName(p.name), localPath: p.localPath)).toList();
    if (entries.isEmpty) return;
    setState(() => _attachments.addAll(entries));
    for (var i = 0; i < entries.length; i++) {
      final p = items[i];
      final a = entries[i];
      try {
        final bytes = await p.readBytes();
        final path = await widget.client.uploadFile(bytes, name: p.name);
        if (!mounted) return;
        setState(() {
          a.remotePath = path;
          a.uploading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _attachments.remove(a));
        _toast('upload failed: ${p.name}');
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
    if (mounted) toast(context, m);
  }

  @override
  void dispose() {
    _closed = true;
    _reconnectTimer?.cancel();
    _ackTimer?.cancel();
    _decisionTimer?.cancel();
    _sub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Only clear the suppression key if this screen still owns it — on a session
    // switch the NEW screen registers before this dispose runs, and clobbering
    // its key made notifications fire for the session being viewed.
    if (_registeredOpenKey == _openKey) {
      _registeredOpenKey = '';
      reportOpenSession('');
    }
    // Flush anything still queued so leaving the chat doesn't lose it — the daemon
    // queues it server-side (pending_inputs) and applies it on the next turn. Give
    // the frames a moment to flush before tearing the socket down.
    final ch = _channel;
    if ((_queued.isNotEmpty || _outbox.isNotEmpty) && ch != null) {
      for (final p in _outbox) {
        ch.sink.add(p);
      }
      _outbox.clear();
      for (final m in _queued) {
        ch.sink.add(jsonEncode({'kind': 'user_message', 'value': m}));
      }
      _queued.clear();
      Future.delayed(const Duration(milliseconds: 300), () => ch.sink.close());
    } else {
      ch?.sink.close();
    }
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _pendingApproval(List<Map<String, dynamic>> events) => _pendingApprovalTotal(events) > 0;

  // How many tool calls this batch is awaiting approval (0 = none pending). Drives
  // whether "Approve all" is shown — it only makes sense with more than one.
  int _pendingApprovalTotal(List<Map<String, dynamic>> events) {
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      final k = e['kind'];
      if (k == 'approval_request') return (e['total'] as num?)?.toInt() ?? 1;
      if (k == 'tool_result' || k == 'assistant_text') return 0;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final status = s?.status ?? 'connecting';
    final running = status == 'running';
    final waiting = status == 'waiting_for_input';
    final events = s?.events ?? const [];
    final items = _transcript(events);
    final scaffold = Scaffold(
      backgroundColor: readingBg,
      body: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (kMobile)
            _mobileHeader(s, running, waiting)
          else
            _desktopBar(s, running),
          // Desktop keeps the detailed chip strip; mobile gets the dense live
          // status rail (ctx gauge · tokens · lanes · watches · rate · mode).
          if (!kMobile) _statusStrip(s, running),
          if (kMobile)
            StatusRail(
              state: s,
              modelLabel: _modelLabel,
              onUsageTap: _showUsage,
              onLanesTap: _showLanes,
            ),
          if (_connError != null) _disconnectedBanner(),
          Expanded(
            child: Stack(children: [
              _centerWide(s == null
                ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)))
                : NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    // ONE SelectionArea over the whole transcript: continuous
                    // selection across paragraphs, markdown blocks, and messages
                    // (per-widget SelectableText could never cross its own bounds).
                    child: SelectionArea(
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
                    ],
                  ),
                ),
                )),
              // Floating "jump to latest": scrolling up unpins auto-follow, and a
              // streaming reply then grows silently — give a one-tap way back.
              if (!_stickToBottom && s != null)
                Positioned(
                  right: 16,
                  bottom: 12,
                  child: Material(
                    color: AppColors.surface2,
                    shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        _stickToBottom = true;
                        setState(() {});
                        _toBottom(jump: true);
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: AppIcon('chevron-down', size: 18, color: AppColors.fg2),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          // The question/approval bars are PINNED here (not inside the scroll
          // list) so a "needs input" request is always visible — buried at the
          // bottom of a scrolled-up transcript it read as "the agent is stuck".
          if (waiting && _pendingApproval(events))
            _centerWide(Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: _ApprovalBar(onSend: _sendDecision, showApproveAll: _pendingApprovalTotal(events) > 1),
            ))
          else if (waiting && s?.pendingQuestion != null)
            _centerWide(Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: _QuestionBar(question: s!.pendingQuestion!, onSend: _sendDecision),
            )),
          _centerWide(_inputBar(running)),
        ]),
      ),
    );
    if (kMobile) return scaffold;
    // Desktop: drop files/images/screenshots anywhere in the session to attach.
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragOver = true),
      onDragExited: (_) => setState(() => _dragOver = false),
      onDragDone: (d) {
        setState(() => _dragOver = false);
        final items = d.files.map((x) => (name: x.name, localPath: x.path, readBytes: x.readAsBytes)).toList();
        if (items.isNotEmpty) _ingest(items);
      },
      child: Stack(children: [
        scaffold,
        if (_dragOver)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: AppColors.accentBg,
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(R.md), border: Border.all(color: AppColors.accent)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const AppIcon('upload', size: 18, color: AppColors.accent),
                    const SizedBox(width: 8),
                    Text('Drop to attach', style: sans(13, color: AppColors.fg1)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
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

  // On desktop, keep chat content to a comfortable reading width (centered),
  // rather than stretching across the whole pane.
  Widget _centerWide(Widget child) => widget.embedded
      ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: child))
      : child;

  // Mobile chat header: a back button that returns to the session list, the
  // title with a live status dot, and a compact subtitle folding in the key
  // facts (status · model · context · approval) — so there's no separate,
  // cramped desktop toolbar + scrolling chip strip on a phone.
  Widget _mobileHeader(HarnessState? s, bool running, bool waiting) {
    final compacting = s?.compacting ?? false;
    final statusWord = compacting
        ? 'Compacting history…'
        : (waiting ? 'Needs input' : (running ? 'Running' : 'Idle'));
    // Just status + model here — ctx/tokens/lanes/watches/rate/mode live in the
    // StatusRail directly below.
    final facts = <String>[
      statusWord,
      if (_modelLabel != null) _modelLabel!,
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(2, 4, 8, 6),
      decoration: BoxDecoration(
        color: readingBg,
        border: const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(children: [
        // Back to the session list (the drawer is the mobile "menu").
        IconBtn('chevron-left', size: 42, iconSize: 28, tooltip: 'Sessions', onTap: widget.onMenu),
        // Tapping the title area itself opens the session actions (rename, model,
        // files, git, …) — no separate ellipsis button needed.
        Expanded(
          child: InkWell(
            onTap: () => _openActions(s),
            borderRadius: BorderRadius.circular(R.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(_title.isEmpty ? 'session' : _title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: sans(16, weight: FontWeight.w600, color: AppColors.fg1)),
                const SizedBox(height: 2),
                Text(facts.join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: sans(11.5, color: AppColors.fg3)),
              ]),
            ),
          ),
        ),
        if (running) IconBtn('stop', tooltip: 'Stop', onTap: () => _send({'kind': 'interrupt'})),
      ]),
    );
  }

  // Compact, desktop-native toolbar for the embedded shell (distinct from the
  // mobile header): slim height, inline muted path, hover-sized controls.
  Widget _desktopBar(HarnessState? s, bool running) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: readingBg,
        border: const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      // Full-width toolbar: title (+path) takes all free space so the actions
      // are pushed to the extreme right.
      child: Row(children: [
        if (widget.onMenu != null) ...[
          IconBtn('sidebar', size: 30, iconSize: 16, tooltip: 'Sidebar', onTap: widget.onMenu),
          const SizedBox(width: 4),
        ] else
          const SizedBox(width: 2),
        Expanded(
          child: Text(_title.isEmpty ? 'session' : _title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(16.5, weight: FontWeight.w600, color: AppColors.fg1)),
        ),
        if (running) IconBtn('stop', size: 30, iconSize: 16, tooltip: 'Stop', onTap: () => _send({'kind': 'interrupt'})),
        _menu(s),
      ]),
    );
  }

  Widget _menu(HarnessState? s) {
    final view = View.of(context);
    final desktop = view.physicalSize.width / view.devicePixelRatio >= kDesktopBreakpoint;
    if (!desktop) {
      return IconBtn('more-vertical', tooltip: 'Actions', onTap: () => _openActions(s));
    }
    return PopupMenuButton<VoidCallback>(
      color: AppColors.surface1,
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

  // Set an autonomous /goal: the agent drives toward it on its own until it's
  // done, you cancel, or it's rate-limited. Sent as a LoopInput over the socket.
  Future<void> _setGoal() async {
    final text = await promptText(context,
        title: 'Set an autonomous goal',
        hint: 'What should the agent work toward on its own?',
        saveLabel: 'Set goal');
    final t = text?.trim();
    if (t == null || t.isEmpty) return;
    _send({'kind': 'set_goal', 'value': t});
    _toast('Goal set — the agent will drive toward it');
  }

  void _cancelGoal() {
    _send({'kind': 'cancel_goal'});
    _toast('Cancelling the goal');
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
      (s?.goal?.ongoing ?? false)
          ? item('zap', 'Cancel goal', _cancelGoal, value: s!.goal!.paused ? 'paused' : 'running')
          : item('zap', 'Set goal', _setGoal),
      if ((s?.lanes.isNotEmpty ?? false))
        item('layers', 'Lanes', _showLanes,
            value: '${s!.lanes.where((l) => l.running).length} running'),
      const PopupMenuDivider(),
      item('git-branch', 'Git', () => presentScreen(context, builder: (_, close) => GitScreen(client: widget.client, sessionId: widget.sessionId, onClose: close))),
      item('folder', 'Browse', () {
        final name = lastPathSegment(ws, ifEmpty: 'Files');
        presentScreen(context, builder: (_, close) => FileExplorer(client: widget.client, title: name, start: ws.isEmpty ? null : ws, onClose: close, onOpenFile: widget.onOpenFileTab));
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
        (s?.goal?.ongoing ?? false)
            ? _actionTile('zap', 'Cancel goal', value: s!.goal!.paused ? 'paused' : 'running', onTap: () => run(_cancelGoal))
            : _actionTile('zap', 'Set goal', onTap: () => run(_setGoal)),
        if ((s?.lanes.isNotEmpty ?? false))
          _actionTile('layers', 'Lanes',
              value: '${s!.lanes.where((l) => l.running).length} running',
              onTap: () => run(_showLanes)),
        const SizedBox(height: 12),
        const SectionLabel('Workspace'),
        _actionTile('git-branch', 'Git', onTap: () => run(() => presentScreen(context,
            builder: (_, close) => GitScreen(client: widget.client, sessionId: widget.sessionId, onClose: close)))),
        _actionTile('folder', 'Open files', onTap: () => run(() {
          final name = lastPathSegment(ws, ifEmpty: 'Files');
          presentScreen(context, builder: (_, close) => FileExplorer(client: widget.client, title: name, start: ws.isEmpty ? null : ws, onClose: close, onOpenFile: widget.onOpenFileTab));
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
        Container(width: 7, height: 7, decoration: BoxDecoration(color: running ? AppColors.run : AppColors.fg2, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(running ? 'Running' : 'Idle', style: sans(12.5, weight: FontWeight.w600, color: running ? AppColors.run : AppColors.fg2)),
      ]),
    ];
    if (s != null && s.workspace.isNotEmpty) {
      chips.add(_StatMeta(icon: 'folder', label: lastPathSegment(s.workspace, ifEmpty: s.workspace)));
    }
    if (_modelLabel != null) chips.add(_StatMeta(icon: 'cpu', label: _modelLabel!));
    if (s != null) {
      if (s.contextWindow > 0 && s.lastPromptTokens > 0) {
        chips.add(_StatMeta(icon: 'activity', label: '${(s.lastPromptTokens / s.contextWindow * 100).clamp(0, 999).round()}% ctx'));
      }
      if (s.totalTokens > 0) chips.add(_StatMeta(icon: 'zap', label: '${fmtSi(s.totalTokens)} tok'));
      chips.add(_StatMeta(icon: 'shield', label: s.approvalMode == 'auto' ? 'Auto-approve' : 'Ask', tone: s.approvalMode == 'auto' ? 'accent' : 'default'));
      // Show for ANY provider that reported limits, not just ChatGPT/Codex.
      final rp = s.ratePrimary;
      if (rp != null) chips.add(_StatMeta(icon: 'clipboard', label: '${rateWindowLabel(rp.windowMinutes)} · ${rp.leftPercent.round()}%', tone: 'run'));
    }
    return Container(
      height: 44,
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
        Expanded(
            child: Text(
                _outbox.isEmpty
                    ? (_connError ?? 'Disconnected')
                    : '${_connError ?? 'Disconnected'} · ${_outbox.length} message${_outbox.length == 1 ? '' : 's'} will send on reconnect',
                style: sans(12, height: 1.3, color: AppColors.fg1))),
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

  // Live send-enabled check — read at tap/submit time and inside the
  // ValueListenableBuilder below, so typing never has to setState the screen.
  bool get _canSend =>
      (_input.text.trim().isNotEmpty || _attachments.any((a) => a.remotePath != null)) &&
      !_anyUploading;

  Widget _inputBar(bool running) {
    return Container(
      padding: EdgeInsets.fromLTRB(12, 4, 12, 8 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_attachments.isNotEmpty) _attachmentBar(),
        // Roomier composer: the text field gets its own line, with a control
        // row (attach · send) beneath it — bigger, and closer in feel to a
        // modern chat composer while staying in our design language.
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(R.card),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Cmd/Ctrl+Enter sends (handy on desktop where Enter inserts a newline).
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, meta: true): () { if (_canSend) _sendMessage(); },
                const SingleActivator(LogicalKeyboardKey.enter, control: true): () { if (_canSend) _sendMessage(); },
              },
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 8,
                cursorColor: AppColors.accent,
                // No onChanged setState: rebuilding the WHOLE screen (incl. the
                // transcript) per keystroke caused typing lag in long sessions.
                // The send button listens to the controller directly below.
                onSubmitted: (_) => _sendMessage(),
                style: sans(15, height: 1.45, color: AppColors.fg1),
                decoration: InputDecoration(
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  border: InputBorder.none,
                  hintText: 'Message snippet…',
                  hintStyle: sans(15, color: AppColors.fg4),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Controls grouped bottom-right (attach next to send) rather than
            // split to opposite corners — reads more balanced under the field.
            Row(children: [
              const Spacer(),
              IconBtn('plus', size: 36, iconSize: 21, tooltip: 'Attach', onTap: _onAttachTap),
              const SizedBox(width: 2),
              // Only the send button re-renders as text changes.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _input,
                builder: (_, __, ___) =>
                    _SendBtn(enabled: _canSend, onTap: _canSend ? _sendMessage : null),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }

  // A single compact pill ("📎 2 attachments") instead of a row of chips. Tap to
  // review/remove individual items; the trailing ✕ clears them all.
  // All pending attachments side by side — image thumbnails and file chips in a
  // horizontally scrollable row, each with its own ✕ so any single one can be
  // removed directly (the old count-pill hid them behind a review sheet).
  Widget _attachmentBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: SizedBox(
        height: 60,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _attachments.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) => _attachmentTile(_attachments[i]),
        ),
      ),
    );
  }

  Widget _attachmentTile(_Attachment a) {
    final thumb = a.isImage && a.localPath != null;
    final body = thumb
        ? ClipRRect(
            borderRadius: BorderRadius.circular(R.sm),
            child: Image.file(File(a.localPath!), width: 60, height: 60, fit: BoxFit.cover),
          )
        : Container(
            width: 118,
            height: 60, // match the image thumbnails so the row is even
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(R.sm),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              AppIcon(a.isImage ? 'image' : 'file', size: 15, color: AppColors.fg3),
              const SizedBox(width: 6),
              Expanded(
                child: Text(a.name,
                    maxLines: 3, overflow: TextOverflow.ellipsis, style: sans(10.5, height: 1.25, color: AppColors.fg2)),
              ),
            ]),
          );
    return Stack(children: [
      body,
      if (a.uploading)
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(R.sm)),
            alignment: Alignment.center,
            child: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg2)),
          ),
        ),
      Positioned(
        top: 3,
        right: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => setState(() => _attachments.remove(a)),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
            child: const AppIcon('x', size: 11, color: AppColors.fg1),
          ),
        ),
      ),
    ]);
  }

  // ---- event → widget (pairs tool_call with its tool_result) ----
  List<Widget> _transcript(List<Map<String, dynamic>> events) {
    final out = <Widget>[];
    Map<String, dynamic>? pending;
    final run = <Widget>[]; // consecutive dense tool rows
    final laneRowsShown = <String>{}; // spawn cards already emitted (by id)

    void flushPending() {
      final p = pending;
      if (p != null) {
        final name = _s(p['tool_name']);
        run.add(DenseToolRow(tool: name, args: p['arguments']));
        pending = null;
      }
    }

    void endTools() {
      flushPending();
      if (run.isEmpty) return;
      out.add(ToolRun(List.of(run)));
      run.clear();
    }

    LaneInfo? liveLane(String id) {
      for (final l in _state?.lanes ?? const <LaneInfo>[]) {
        if (l.id == id) return l;
      }
      return null;
    }

    for (final e in events) {
      final k = e['kind'] as String? ?? '';
      switch (k) {
        case 'tool_call':
          flushPending();
          // Meta-tools render via their own events (note → note, ask_user →
          // user_question, delegate_task → lane_spawned). Skip their generic tool
          // lines so they don't double up.
          if (_isMetaTool(_s(e['tool_name']))) break;
          pending = e;
        case 'tool_result':
          {
            final p = pending;
            if (p != null) {
              run.add(DenseToolRow(tool: _s(p['tool_name']), args: p['arguments'], result: e['result']));
              pending = null;
            } else {
              final name = _s(e['tool_name']);
              if (_isMetaTool(name)) break;
              run.add(DenseToolRow(tool: name, result: e['result']));
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
          out.add(SystemRow(step: _s(e['step']), reasoning: _s(e['reasoning'])));
        case 'file_presented':
          endTools();
          out.add(_presentedFileCard(_s(e['path']), _s(e['caption'])));
        case 'lane_spawned':
          endTools();
          final id = _s(e['id']);
          final title = _s(e['title']);
          laneRowsShown.add(id);
          // Live card: resolves the current record each build, so it flips
          // running → done (with summary) in place.
          out.add(LaneCard(title: title, live: () => liveLane(id)));
        case 'lane_completed':
          endTools();
          final id = _s(e['id']);
          // The spawn card already tracks this lane live — only render a card
          // here if the spawn row is gone (e.g. compacted away).
          if (!laneRowsShown.contains(id)) {
            out.add(LaneCard(title: _s(e['title']), live: () => liveLane(id), summary: _s(e['summary'])));
          }
        case 'user_question':
          endTools();
          final qd = e['questions'];
          final qs = (qd is Map ? qd['questions'] : null) as List?;
          final txt = (qs != null && qs.isNotEmpty && qs.first is Map) ? _s((qs.first as Map)['text']) : '';
          if (txt.isNotEmpty) {
            out.add(Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const AppIcon('corner-down-right', size: 15, color: AppColors.run),
                const SizedBox(width: 8),
                Expanded(child: Text(txt, style: sans(13.5, height: 1.45, weight: FontWeight.w500, color: AppColors.fg2))),
              ]),
            ));
          }
        case 'approval_request':
          break; // shown by the approval bar
        default:
          break;
      }
    }
    endTools();
    return out;
  }

  /// A file the agent handed over (present_file): an openable card — tap to
  /// view it in the editor.
  Widget _presentedFileCard(String path, String caption) {
    final name = path.split('/').last;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        onTap: () => presentScreen(
          context,
          builder: (_, close) => EditorScreen(client: widget.client, path: path, name: name, onClose: close),
        ),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.accentBg, borderRadius: BorderRadius.circular(R.sm)),
            child: const AppIcon('file', size: 16, color: AppColors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(13, color: AppColors.fg1)),
              const SizedBox(height: 2),
              Text(caption.isNotEmpty ? caption : path, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(11.5, color: AppColors.fg3)),
            ]),
          ),
          const SizedBox(width: 8),
          const AppIcon('chevron-right', size: 16, color: AppColors.fg4),
        ]),
      ),
    );
  }

  String _s(dynamic v) => v?.toString() ?? '';

  // Meta-tools have dedicated event rendering, so their generic tool lines are skipped.
  bool _isMetaTool(String n) =>
      n == 'note' || n == 'ask_user' || n == 'delegate_task' || n == 'complete_goal' || n == 'monitor' || n == 'present_file';

  void _showNote(String text) {
    showAppSheet(context, title: 'Note', child: SelectableText(text, style: sans(13.5, height: 1.5, color: AppColors.fg1)));
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
          if (!ctx.mounted) return; // sheet dismissed mid-command
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
      // Free the controller when the sheet closes (it leaked one per open).
    )).whenComplete(ctrl.dispose);
  }

  // Live lane status: every delegated lane with a status dot, elapsed time for
  // running ones, and the summary for finished ones.
  void _showLanes() {
    final lanes = _state?.lanes ?? const <LaneInfo>[];
    if (lanes.isEmpty) return;
    String elapsed(String startedAt) {
      final t = DateTime.tryParse(startedAt);
      if (t == null) return '';
      final d = DateTime.now().toUtc().difference(t.toUtc());
      if (d.inMinutes < 1) return '${d.inSeconds}s';
      if (d.inHours < 1) return '${d.inMinutes}m';
      return '${d.inHours}h ${d.inMinutes % 60}m';
    }

    showAppSheet(context, title: 'Lanes', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in lanes.reversed) Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: l.running
                      ? AppColors.accent
                      : (l.status == 'failed' ? AppColors.danger : AppColors.ok),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.title, style: sans(13.5, weight: FontWeight.w500, color: AppColors.fg1)),
                const SizedBox(height: 2),
                Text(
                  l.running
                      ? 'running · ${elapsed(l.startedAt)}'
                      : (l.summary?.trim().isNotEmpty == true ? '${l.status} — ${l.summary}' : l.status),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: sans(11.5, height: 1.35, color: AppColors.fg3),
                ),
              ]),
            ),
          ]),
        ),
      ],
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
                final reset = rateResetLabel(w.resetsAt);
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(rateWindowLabel(w.windowMinutes), style: sans(12, color: AppColors.fg2)),
                    Text('${rem.round()}% left', style: mono(11, color: color)),
                  ]),
                  const SizedBox(height: 6),
                  Progress(pct: rem, color: color, height: 6),
                  if (reset != null) ...[
                    const SizedBox(height: 5),
                    Text(reset, style: mono(10.5, color: AppColors.fg4)),
                  ],
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
      AppIcon(icon, size: 14, color: tone == 'default' ? AppColors.fg4 : c),
      const SizedBox(width: 6),
      Text(label, style: mono(12.5, color: c)),
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

class _ApprovalBar extends StatefulWidget {
  final void Function(Map<String, dynamic>) onSend;
  final bool showApproveAll; // only when >1 tool is pending this batch
  const _ApprovalBar({required this.onSend, this.showApproveAll = false});
  @override
  State<_ApprovalBar> createState() => _ApprovalBarState();
}

class _ApprovalBarState extends State<_ApprovalBar> {
  // Disable after the first tap — the bar stays on screen until the next frame
  // flips status, so an impatient double-tap fired the decision twice.
  bool _sent = false;

  void _decide(Map<String, dynamic> m) {
    if (_sent) return;
    setState(() => _sent = true);
    widget.onSend(m);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: AppColors.accentBg, border: Border.all(color: AppColors.accentLine), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: AppIcon('shield', size: 16, color: AppColors.accent)),
          const SizedBox(width: 9),
          Expanded(child: Text(_sent ? 'Sending…' : 'Approve this action?', style: sans(13, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1))),
        ]),
        const SizedBox(height: 11),
        Opacity(
          opacity: _sent ? 0.5 : 1,
          child: Row(children: [
            Expanded(child: Btn('Approve', small: true, icon: 'check', onTap: _sent ? null : () => _decide({'kind': 'approve'}))),
            const SizedBox(width: 8),
            if (widget.showApproveAll) ...[
              Expanded(child: Btn('Approve all', small: true, variant: BtnVariant.secondary, icon: 'check-check', onTap: _sent ? null : () => _decide({'kind': 'approve_all'}))),
              const SizedBox(width: 8),
            ],
            Btn('Deny', small: true, variant: BtnVariant.ghost, onTap: _sent ? null : () => _decide({'kind': 'deny'})),
          ]),
        ),
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
  // One answer per ask — the bar lingers until the next frame flips status,
  // so an eager second tap double-submitted the answer.
  bool _sent = false;

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
    if (!_ready || _sent) return;
    setState(() => _sent = true);
    final multi = _questions.length > 1;
    final parts = _questions.map((q) {
      final id = q['id'].toString();
      final a = _kind(q) == 'free_text' ? (_text[id]?.text.trim() ?? '') : (_choice[id] ?? '');
      return multi ? '${q['text']}\n→ $a' : a;
    }).toList();
    widget.onSend({'kind': 'answer', 'value': parts.join('\n\n')});
  }

  Widget _chip(String label, bool sel, VoidCallback onTap) => Material(
        color: sel ? AppColors.accentBg : AppColors.surface2,
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(99),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: sel ? AppColors.accentLine : AppColors.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Text(label, style: sans(13, weight: FontWeight.w600, color: sel ? AppColors.accent : AppColors.fg2)),
          ),
        ),
      );

  // Full-width selectable row for single-choice options (labels are sentences).
  // Selected reads as a quiet accent tint + border + check, not a solid orange slab.
  Widget _choiceRow(String label, bool sel, VoidCallback onTap) => Material(
        color: sel ? AppColors.accentBg : AppColors.surface2,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? AppColors.accentLine : AppColors.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              Expanded(child: Text(label, style: sans(14, height: 1.4, weight: FontWeight.w500, color: sel ? AppColors.fg1 : AppColors.fg2))),
              if (sel) ...[const SizedBox(width: 10), const AppIcon('check', size: 16, color: AppColors.accent)],
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
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // A quiet eyebrow — accent dot + label — rather than an alarm-triangle box.
        Row(children: [
          Container(width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle)),
          const SizedBox(width: 9),
          Text('NEEDS YOUR INPUT', style: sans(11, weight: FontWeight.w600, spacing: 0.6, color: AppColors.fg3)),
        ]),
        if (ctx != null && ctx.isNotEmpty && ctx != 'null') ...[
          const SizedBox(height: 12),
          Text(ctx, style: sans(13, height: 1.45, color: AppColors.fg2)),
        ],
        for (final q in _questions) ...[
          const SizedBox(height: 15),
          Text(q['text']?.toString() ?? '', style: sans(15, weight: FontWeight.w600, height: 1.4, color: AppColors.fg1)),
          const SizedBox(height: 11),
          ..._inputFor(q),
        ],
        const SizedBox(height: 16),
        Btn(_sent ? 'Sending…' : 'Send answer', small: true, icon: 'send', full: true, disabled: !_ready || _sent, onTap: (_ready && !_sent) ? _submit : null),
      ]),
    );
  }
}

/// A pending composer attachment (image or file) being uploaded to the workspace.
class _Attachment {
  final String name;
  final bool isImage;
  final String? localPath; // local source (for image thumbnails)
  String? remotePath; // daemon path once uploaded
  bool uploading = true;
  _Attachment({required this.name, required this.isImage, this.localPath});
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
          width: 38,
          height: 38,
          child: Center(child: AppIcon('send', size: 18, color: enabled ? AppColors.accentFg : AppColors.fg4)),
        ),
      ),
    );
  }
}
