import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api.dart';
import '../models.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets.dart';

/// Accepts `https://host?token=…` or JSON `{url, token}`.
(String, String)? parseConnection(String raw) {
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

/// Compact desktop "Connect a machine" dialog (phones use the full-screen
/// scanner flow). Natural height; Esc dismisses, Enter submits. Yields the
/// verified [Instance].
Future<Instance?> showAddMachineDialog(BuildContext context) {
  return showGeneralDialog<Instance>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'add-machine',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, __, ___) => const Center(child: _AddMachineDialog()),
    transitionBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(curved), child: child),
      );
    },
  );
}

class _AddMachineDialog extends StatefulWidget {
  const _AddMachineDialog();
  @override
  State<_AddMachineDialog> createState() => _AddMachineDialogState();
}

class _AddMachineDialogState extends State<_AddMachineDialog> {
  final _paste = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _paste.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _connect(String raw) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final parsed = parseConnection(raw);
      if (parsed == null) throw 'That is not a valid connection string.';
      final (url, token) = parsed;
      final cfg = await DaemonClient(url, token).getConfig();
      final name = cfg.hostname.isNotEmpty ? cfg.hostname : hostOf(url);
      if (mounted) Navigator.pop(context, Instance(name: name, url: url, token: token));
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
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(R.card),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: 460,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(color: AppColors.border2),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Connect a machine', style: display(17)),
          const SizedBox(height: 8),
          Text('Run this on the machine you want to control, then paste the connection string it prints.',
              style: sans(12.5, height: 1.45, color: AppColors.fg3)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(R.sm)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const AppIcon('terminal', size: 13, color: AppColors.fg3),
              const SizedBox(width: 8),
              Text('snippet serve', style: mono(12, color: AppColors.fg2)),
            ]),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: AppField(
                    controller: _paste,
                    mono: true,
                    autofocus: true,
                    hint: 'Paste connection string or URL',
                    onSubmitted: _connect)),
            const SizedBox(width: 10),
            if (_busy)
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                child: const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentFg)),
              )
            else
              PillBtn('Connect', onTap: _paste.text.trim().isEmpty ? null : () => _connect(_paste.text)),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: sans(11.5, color: AppColors.danger)),
          ],
        ]),
      ),
    );
  }
}

/// Full-screen "Add machine": a live QR scanner on phones (desktop shows an
/// instruction block instead), plus a fixed paste-a-connection-string bar at
/// the bottom. Pops with the verified [Instance].
class AddInstanceScreen extends StatefulWidget {
  const AddInstanceScreen({super.key});
  @override
  State<AddInstanceScreen> createState() => _AddInstanceScreenState();
}

class _AddInstanceScreenState extends State<AddInstanceScreen> with WidgetsBindingObserver {
  final _paste = TextEditingController();
  PermissionStatus? _perm;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kMobile) {
      Permission.camera.request().then((s) => mounted ? setState(() => _perm = s) : null);
    }
    _paste.addListener(() => setState(() {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!kMobile) return;
    if (state == AppLifecycleState.resumed) {
      Permission.camera.status.then((s) => (mounted && s != _perm) ? setState(() => _perm = s) : null);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _paste.dispose();
    super.dispose();
  }

  Future<void> _connect(String raw) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final parsed = parseConnection(raw);
      if (parsed == null) throw 'That is not a valid connection string.';
      final (url, token) = parsed;
      final client = DaemonClient(url, token);
      final cfg = await client.getConfig();
      final name = cfg.hostname.isNotEmpty ? cfg.hostname : hostOf(url);
      if (mounted) Navigator.pop(context, Instance(name: name, url: url, token: token));
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
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: 'Add machine', onBack: () => Navigator.pop(context)),
          // Phone-only screen now (desktop uses the compact dialog above).
          Expanded(child: _scanArea()),
          _bottomBar(),
        ]),
      ),
    );
  }

  Widget _scanArea() {
    final perm = _perm;
    if (perm == null) {
      return const ColoredBox(color: AppColors.surface1, child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))));
    }
    if (!perm.isGranted) {
      final permanent = perm.isPermanentlyDenied || perm.isRestricted;
      return ColoredBox(
        color: AppColors.surface1,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 56, height: 56, decoration: BoxDecoration(color: AppColors.surface2, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(R.card)), child: const AppIcon('camera-off', size: 26, color: AppColors.fg3)),
              const SizedBox(height: 12),
              Text('Camera access needed', style: sans(15, weight: FontWeight.w600, color: AppColors.fg1)),
              const SizedBox(height: 8),
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 250), child: Text('Grant camera access to scan a QR, or paste your connection string below.', textAlign: TextAlign.center, style: sans(12.5, height: 1.5, color: AppColors.fg3))),
              const SizedBox(height: 16),
              Btn('Grant camera access', variant: BtnVariant.secondary, icon: 'camera', onTap: () {
                if (permanent) {
                  openAppSettings();
                } else {
                  Permission.camera.request().then((s) => mounted ? setState(() => _perm = s) : null);
                }
              }),
            ]),
          ),
        ),
      );
    }
    // Rounded viewport, Claude-card style, with the scan reticle + caption inside.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(alignment: Alignment.center, fit: StackFit.expand, children: [
          ReaderWidget(
            showScannerOverlay: false,
            showGallery: false,
            tryHarder: true,
            tryInverted: true,
            cropPercent: 0.7,
            scanDelay: const Duration(milliseconds: 300),
            onScan: (code) {
              final raw = code.text;
              if (code.isValid && raw != null && raw.trim().isNotEmpty) _connect(raw);
            },
          ),
          const IgnorePointer(child: Center(child: _Reticle())),
          Positioned(
            bottom: 18,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(99)),
                child: Text.rich(
                  TextSpan(style: sans(12.5, color: AppColors.fg1), children: [
                    const TextSpan(text: 'Scan the QR from '),
                    TextSpan(text: 'snippet serve', style: mono(12, color: AppColors.fg1)),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _bottomBar() {
    final empty = _paste.text.trim().isEmpty;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 14 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: AppField(controller: _paste, mono: true, hint: 'Paste connection string or URL', onSubmitted: _connect)),
          const SizedBox(width: 10),
          if (_busy)
            Container(
              width: kMobile ? 48 : 36,
              height: kMobile ? 48 : 36,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
              child: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentFg)),
            )
          else
            PillBtn('Connect', onTap: empty ? null : () => _connect(_paste.text)),
        ]),
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: sans(11.5, color: AppColors.danger))],
      ]),
    );
  }
}

class _Reticle extends StatefulWidget {
  const _Reticle();
  @override
  State<_Reticle> createState() => _ReticleState();
}

class _ReticleState extends State<_Reticle> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _corner(Alignment a) {
    final top = a.y < 0, left = a.x < 0;
    return Align(
      alignment: a,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          border: Border(
            top: top ? const BorderSide(color: AppColors.accent, width: 3) : BorderSide.none,
            bottom: !top ? const BorderSide(color: AppColors.accent, width: 3) : BorderSide.none,
            left: left ? const BorderSide(color: AppColors.accent, width: 3) : BorderSide.none,
            right: !left ? const BorderSide(color: AppColors.accent, width: 3) : BorderSide.none,
          ),
          borderRadius: BorderRadius.only(
            topLeft: top && left ? const Radius.circular(12) : Radius.zero,
            topRight: top && !left ? const Radius.circular(12) : Radius.zero,
            bottomLeft: !top && left ? const Radius.circular(12) : Radius.zero,
            bottomRight: !top && !left ? const Radius.circular(12) : Radius.zero,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 232,
      height: 232,
      child: Stack(children: [
        _corner(Alignment.topLeft),
        _corner(Alignment.topRight),
        _corner(Alignment.bottomLeft),
        _corner(Alignment.bottomRight),
        AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Positioned(
            left: 8,
            right: 8,
            top: 8 + _c.value * 216,
            child: Container(height: 2, decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(99), boxShadow: const [BoxShadow(color: AppColors.accent, blurRadius: 12)])),
          ),
        ),
      ]),
    );
  }
}
