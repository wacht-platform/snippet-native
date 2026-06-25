import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';

/// Paste the connection string printed by `snippet serve` (the JSON under the
/// QR code: {"url":..., "token":...}). QR camera scanning is a planned follow-up.
class ConnectScreen extends StatefulWidget {
  final Future<void> Function(DaemonClient) onConnected;
  const ConnectScreen({super.key, required this.onConnected});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final raw = _controller.text.trim();
      if (raw.isEmpty) throw 'Paste the connection string first.';
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw 'That is not a valid connection string.';
      final url = (decoded['url'] as String?)?.trim();
      final token = (decoded['token'] as String?)?.trim();
      if (url == null || url.isEmpty || token == null || token.isEmpty) {
        throw 'Connection string is missing "url" or "token".';
      }
      final client = DaemonClient(url, token);
      if (!await client.health()) {
        throw 'Could not reach the daemon at $url.';
      }
      await widget.onConnected(client);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text('Connect to snippet serve',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'Run `snippet serve` on your machine and paste the connection '
              'string it prints (the JSON shown beneath the QR code).',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              maxLines: 4,
              autocorrect: false,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '{"url":"https://...","token":"..."}',
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
