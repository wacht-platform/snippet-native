import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

// (value sent to the daemon, label shown in the pill)
const _providers = [
  ('anthropic', 'Anthropic'),
  ('openai', 'OpenAI'),
  ('gemini', 'Google'),
  ('openai-compatible', 'OpenAI-compatible'),
  ('openrouter', 'OpenRouter'),
];

bool _needsBaseUrl(String p) => p == 'openai-compatible';
bool _defaultImages(String p) => p == 'anthropic' || p == 'gemini' || p == 'openai' || p == 'chatgpt';

class ModelEditorScreen extends StatefulWidget {
  final DaemonClient client;
  final ModelProfile? existing;
  /// Dismiss when hosted in a responsive panel (desktop drawer / phone full-screen).
  final VoidCallback? onClose;
  const ModelEditorScreen({super.key, required this.client, this.existing, this.onClose});
  @override
  State<ModelEditorScreen> createState() => _ModelEditorScreenState();
}

class _ModelEditorScreenState extends State<ModelEditorScreen> {
  late String _provider;
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _ctx;
  final _key = TextEditingController();
  bool _showKey = false;
  late bool _images;
  bool _active = false;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existing != null;
  bool get _isChatgpt => _provider == 'chatgpt';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _provider = e?.provider ?? 'anthropic';
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _ctx = TextEditingController(text: (e?.contextWindow ?? 0) > 0 ? '${e!.contextWindow}' : '');
    _images = _defaultImages(_provider);
    _active = e?.active ?? !_isEdit;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _ctx.dispose();
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
        name: _isEdit ? widget.existing!.name : (_name.text.trim().isEmpty ? null : _name.text.trim()),
        provider: _provider,
        baseUrl: _needsBaseUrl(_provider) ? _baseUrl.text.trim() : null,
        model: _model.text.trim(),
        apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
        supportsImages: _images,
        contextWindow: int.tryParse(_ctx.text.trim()),
        setActive: _active,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // include the current provider as a pill even if it's outside the standard list (e.g. chatgpt)
    final pills = [..._providers];
    if (!pills.any((p) => p.$1 == _provider)) pills.insert(0, (_provider, _provider));
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: _isEdit ? 'Edit model' : 'Add model', onBack: widget.onClose ?? () => Navigator.pop(context)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Provider', style: sans(12, weight: FontWeight.w500, color: AppColors.fg2)),
                const SizedBox(height: 7),
                Wrap(spacing: 7, runSpacing: 7, children: [
                  for (final (val, label) in pills)
                    GestureDetector(
                      onTap: _isEdit ? null : () => setState(() {
                        _provider = val;
                        _images = _defaultImages(val);
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                        decoration: BoxDecoration(
                          color: _provider == val ? AppColors.accentBg : AppColors.surface2,
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(color: _provider == val ? AppColors.accentLine : AppColors.border),
                        ),
                        child: Text(label, style: sans(12.5, weight: FontWeight.w500, color: _provider == val ? AppColors.accent : AppColors.fg2)),
                      ),
                    ),
                ]),
                const SizedBox(height: 16),
                if (!_isEdit) ...[
                  AppField(label: 'Profile name', controller: _name, hint: 'optional — defaults to the provider'),
                  const SizedBox(height: 16),
                ],
                if (_needsBaseUrl(_provider)) ...[
                  AppField(label: 'Base URL', controller: _baseUrl, mono: true, hint: 'https://api.example.com/v1'),
                  const SizedBox(height: 16),
                ],
                AppField(label: 'Model', controller: _model, mono: true, hint: 'claude-sonnet-4.5'),
                const SizedBox(height: 16),
                AppField(
                  label: 'Context window (tokens)',
                  controller: _ctx,
                  mono: true,
                  keyboardType: TextInputType.number,
                  hint: 'e.g. 200000 — blank keeps the default',
                  helper: 'Sets the % context gauge and the point where the agent compacts history.',
                ),
                const SizedBox(height: 16),
                if (_isChatgpt)
                  Text('ChatGPT uses the subscription login set up in the TUI — no API key here.', style: sans(12, height: 1.4, color: AppColors.fg3))
                else
                  AppField(
                    label: 'API key',
                    controller: _key,
                    mono: true,
                    obscure: !_showKey,
                    icon: 'key',
                    hint: _isEdit && widget.existing!.hasKey ? 'leave blank to keep current key' : 'sk-…',
                    helper: 'Stored on the machine running snippet. Never sent to snippet servers.',
                    rightSlot: GestureDetector(
                      onTap: () => setState(() => _showKey = !_showKey),
                      child: Padding(padding: const EdgeInsets.all(4), child: Text(_showKey ? 'Hide' : 'Show', style: sans(11, color: AppColors.fg3))),
                    ),
                  ),
                const SizedBox(height: 16),
                AppToggle(on: _images, onChanged: (v) => setState(() => _images = v), label: 'Supports images', sub: 'Send screenshots and diagrams to this model'),
                const SizedBox(height: 8),
                AppToggle(on: _active, onChanged: (v) => setState(() => _active = v), label: 'Set as active', sub: 'Use this model for new sessions'),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: sans(12, color: AppColors.danger)),
                ],
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
            child: Row(children: [
              Btn('Cancel', variant: BtnVariant.ghost, onTap: widget.onClose ?? () => Navigator.pop(context)),
              const SizedBox(width: 8),
              Expanded(child: Btn(_busy ? 'Saving…' : 'Save', full: true, disabled: _busy || _model.text.trim().isEmpty, onTap: _save)),
            ]),
          ),
        ]),
      ),
    );
  }
}
