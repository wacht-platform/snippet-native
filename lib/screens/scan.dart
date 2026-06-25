import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme.dart';

/// Full-screen QR scanner. Explicitly requests camera permission (mobile_scanner
/// wasn't prompting on its own), then shows the scanner and pops the decoded string.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;
  PermissionStatus? _perm;

  @override
  void initState() {
    super.initState();
    _request();
  }

  Future<void> _request() async {
    final status = await Permission.camera.request();
    if (mounted) setState(() => _perm = status);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || !mounted) return;
    final raw =
        capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (raw == null || raw.trim().isEmpty) return;
    _done = true;
    Navigator.pop(context, raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    final perm = _perm;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: perm == null
          ? const Center(child: CircularProgressIndicator())
          : perm.isGranted
              ? _scanner()
              : _denied(perm.isPermanentlyDenied || perm.isRestricted),
    );
  }

  Widget _scanner() {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(
          onDetect: _onDetect,
          errorBuilder: (context, error) => _denied(false),
        ),
        IgnorePointer(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        Positioned(
          bottom: 48,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text('Point at the snippet serve QR',
                style: TextStyle(color: Colors.white)),
          ),
        ),
      ],
    );
  }

  Widget _denied(bool permanent) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                color: AppColors.muted, size: 48),
            const SizedBox(height: 16),
            const Text('Camera permission needed',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              permanent
                  ? 'Enable camera access in Settings to scan, or go back and paste the connection string.'
                  : 'Allow camera access to scan the QR, or go back and paste the connection string.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: permanent ? openAppSettings : _request,
              child: Text(permanent ? 'Open settings' : 'Allow camera'),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Back to paste'),
            ),
          ],
        ),
      ),
    );
  }
}
