import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';

/// Add a daemon: the camera scanner opens by default; a bar at the bottom lets you
/// paste the connection string (URL?token) instead. The instance name defaults to
/// the machine's hostname (reported by the daemon). Returns the [Instance] via pop.
class AddInstanceScreen extends StatefulWidget {
  const AddInstanceScreen({super.key});

  @override
  State<AddInstanceScreen> createState() => _AddInstanceScreenState();
}

class _AddInstanceScreenState extends State<AddInstanceScreen>
    with WidgetsBindingObserver {
  final _paste = TextEditingController();
  PermissionStatus? _perm;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Permission.camera.request().then((s) {
      if (mounted) setState(() => _perm = s);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check in case the permission was toggled in system settings while away.
    if (state == AppLifecycleState.resumed) {
      Permission.camera.status.then((s) {
        if (mounted && s != _perm) setState(() => _perm = s);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _paste.dispose();
    super.dispose();
  }

  (String, String)? _parse(String raw) {
    raw = raw.trim();
    final uri = Uri.tryParse(raw);
    if (uri != null &&
        uri.scheme.startsWith('http') &&
        (uri.queryParameters['token'] ?? '').isNotEmpty) {
      final token = uri.queryParameters['token']!;
      final port = uri.hasPort ? ':${uri.port}' : '';
      return ('${uri.scheme}://${uri.host}$port', token);
    }
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['url'] is String && m['token'] is String) {
        return (m['url'] as String, m['token'] as String);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _connect(String raw) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final parsed = _parse(raw);
      if (parsed == null) throw 'That is not a valid connection string.';
      final (url, token) = parsed;
      final client = DaemonClient(url, token);
      // getConfig validates the token (401 if wrong) and reports the hostname.
      final cfg = await client.getConfig();
      final name = cfg.hostname.isNotEmpty ? cfg.hostname : hostOf(url);
      if (mounted) {
        Navigator.pop(context, Instance(name: name, url: url, token: token));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not connect: $e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add instance')),
      body: Column(
        children: [
          Expanded(child: _scannerArea()),
          _pasteBar(),
        ],
      ),
    );
  }

  Widget _scannerArea() {
    final perm = _perm;
    if (perm == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!perm.isGranted) {
      return _CameraOff(
        permanent: perm.isPermanentlyDenied || perm.isRestricted,
        onAllow: () =>
            Permission.camera.request().then((s) => setState(() => _perm = s)),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        QRCodeDartScanView(
          typeScan: TypeScan.live,
          onCapture: (result) {
            final raw = result.text;
            if (raw.trim().isNotEmpty) _connect(raw);
          },
        ),
        IgnorePointer(
          child: Container(
            width: 230,
            height: 230,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(22),
            ),
          ),
        ),
        const Positioned(
          bottom: 20,
          child: _Hint('Point at the snippet serve QR'),
        ),
      ],
    );
  }

  Widget _pasteBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('…or paste the connection string',
                style: TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _paste,
                    autocorrect: false,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      hintText: 'https://host/?token=...',
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    onSubmitted: (v) => _connect(v),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 46,
                  child: FilledButton(
                    onPressed: _busy ? null : () => _connect(_paste.text),
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Go'),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!,
                    style: const TextStyle(color: AppColors.offline)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white)),
    );
  }
}

class _CameraOff extends StatelessWidget {
  final bool permanent;
  final VoidCallback? onAllow;
  const _CameraOff({required this.permanent, this.onAllow});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined,
              color: AppColors.muted, size: 44),
          const SizedBox(height: 14),
          const Text('Camera off — paste the connection string below',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted)),
          if (onAllow != null) ...[
            const SizedBox(height: 16),
            FilledButton(
              onPressed: permanent ? openAppSettings : onAllow,
              child: Text(permanent ? 'Open settings' : 'Allow camera'),
            ),
          ],
        ],
      ),
    );
  }
}
