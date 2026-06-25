import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';

/// Add a daemon by pasting the connection string `snippet serve` prints
/// ({"url":..., "token":...}). Returns the validated [Instance] via pop.
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

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final raw = _conn.text.trim();
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
              'Run `snippet serve` and paste the connection string it prints. '
              '(QR scanning is coming soon.)',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _conn,
              maxLines: 4,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Connection string',
                border: OutlineInputBorder(),
                hintText: '{"url":"https://...","token":"..."}',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                border: OutlineInputBorder(),
                hintText: 'e.g. my laptop',
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
