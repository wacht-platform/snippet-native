import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';

const _providers = [
  'openai-compatible',
  'openai',
  'anthropic',
  'gemini',
  'openrouter',
];

bool _needsBaseUrl(String provider) =>
    provider == 'openai-compatible' || provider == 'openrouter';

bool _defaultImages(String provider) =>
    provider == 'anthropic' ||
    provider == 'gemini' ||
    provider == 'openai' ||
    provider == 'chatgpt';

/// Add or edit an API-key model profile. ChatGPT-subscription (OAuth) is set up
/// from the TUI, not here.
class ModelEditorScreen extends StatefulWidget {
  final DaemonClient client;
  final ModelProfile? existing;
  const ModelEditorScreen({super.key, required this.client, this.existing});

  @override
  State<ModelEditorScreen> createState() => _ModelEditorScreenState();
}

class _ModelEditorScreenState extends State<ModelEditorScreen> {
  late String _provider;
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  final _key = TextEditingController();
  late bool _images;
  bool _setActive = false;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    // Keep the real provider when editing (e.g. a chatgpt profile set up in the TUI);
    // new profiles default to an API-key provider.
    _provider = e?.provider ?? 'openai-compatible';
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _images = _defaultImages(_provider);
    _setActive = e?.active ?? !_isEdit; // new profiles default to active
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_model.text.trim().isEmpty) throw 'Model is required.';
      await widget.client.putProfile(
        name: _isEdit ? widget.existing!.name : _name.text.trim(),
        provider: _provider,
        baseUrl: _needsBaseUrl(_provider) ? _baseUrl.text.trim() : null,
        model: _model.text.trim(),
        apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
        supportsImages: _images,
        setActive: _setActive,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit model' : 'Add model')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              dropdownColor: AppColors.surfaceAlt,
              items: <String>{..._providers, _provider}
                  .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                  .toList(),
              onChanged: _isEdit
                  ? null
                  : (v) => setState(() {
                        _provider = v ?? _provider;
                        _images = _defaultImages(_provider);
                      }),
            ),
            const SizedBox(height: 14),
            if (!_isEdit)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name (optional)',
                    hintText: 'defaults to the provider name',
                  ),
                ),
              ),
            if (_needsBaseUrl(_provider))
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: TextField(
                  controller: _baseUrl,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.example.com/v1',
                  ),
                ),
              ),
            TextField(
              controller: _model,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'e.g. gpt-4o, claude-opus-4-8, gemini-3.5-flash',
              ),
            ),
            const SizedBox(height: 14),
            if (_provider == 'chatgpt')
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'ChatGPT uses the subscription login set up in the TUI — no API key here.',
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              )
            else
              TextField(
                controller: _key,
                obscureText: true,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'API key',
                  hintText: _isEdit && widget.existing!.hasKey
                      ? 'leave blank to keep current key'
                      : 'paste your API key',
                ),
              ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Supports images'),
              subtitle: const Text('multimodal models only',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              value: _images,
              onChanged: (v) => setState(() => _images = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Set as active'),
              subtitle: const Text('default model for new sessions',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              value: _setActive,
              onChanged: (v) => setState(() => _setActive = v),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: const TextStyle(color: AppColors.offline)),
              ),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_isEdit ? 'Save' : 'Add model'),
            ),
          ],
        ),
      ),
    );
  }
}
