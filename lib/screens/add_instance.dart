import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'scan.dart';

/// Add a daemon by scanning the serve QR or pasting the connection string: the
/// public URL carrying the token (https://host/?token=...). Raw JSON also works.
class AddInstanceScreen extends StatefulWidget {
  const AddInstanceScreen({super.key});

  @override
  State<AddInstanceScreen> createState() => _AddInstanceScreenState();
}

class _AddInstanceScreenState extends State<AddInstanceScreen> {
  final _conn = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _conn.dispose();
    _name.dispose();
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

  Future<void> _scan() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (raw != null && raw.isNotEmpty) {
      _conn.text = raw;
      await _submit();
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final parsed = _parse(_conn.text);
      if (parsed == null) throw 'That is not a valid connection string.';
      final (url, token) = parsed;
      final client = DaemonClient(url, token);
      if (!await client.health()) {
        throw 'Could not reach the daemon at $url.';
      }
      final name = _name.text.trim().isEmpty ? hostOf(url) : _name.text.trim();
      if (mounted) {
        Navigator.pop(context, Instance(name: name, url: url, token: token));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add instance')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Run `snippet serve`, then scan its QR or paste the connection '
              'string it prints.',
              style: TextStyle(color: AppColors.muted, height: 1.4),
            ),
            const SizedBox(height: 22),
            OutlinedButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner, color: AppColors.accent),
              label: const Text('Scan QR'),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or paste',
                      style: TextStyle(color: AppColors.muted, fontSize: 13)),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _conn,
              maxLines: 3,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Connection string',
                hintText: 'https://host/?token=...',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                hintText: 'e.g. my laptop',
              ),
            ),
            const SizedBox(height: 18),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: const TextStyle(color: AppColors.offline)),
              ),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}
