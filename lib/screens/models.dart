import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'model_editor.dart';

class ModelsScreen extends StatefulWidget {
  final DaemonClient client;
  const ModelsScreen({super.key, required this.client});
  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  late Future<ServerConfig> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.client.getConfig();
  }

  void _refresh() => setState(() { _future = widget.client.getConfig(); });

  Future<void> _run(Future<void> Function() op, String onError) async {
    try {
      await op();
      _refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$onError: $e')));
    }
  }

  Future<void> _edit(ModelProfile? p) async {
    final saved = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => ModelEditorScreen(client: widget.client, existing: p)));
    if (saved == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: 'Models', onBack: () => Navigator.pop(context)),
          Expanded(
            child: FutureBuilder<ServerConfig>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)));
                }
                final profiles = snap.data?.profiles ?? const [];
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  children: [
                    if (profiles.isEmpty) ...[
                      const EmptyState(icon: 'cpu', title: 'No model configured', body: 'Add a model profile with an API key before starting a session.'),
                      const SizedBox(height: 10),
                    ],
                    ...profiles.map((p) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: AppCard(
                            onTap: p.hasKey ? () => _run(() => widget.client.setActiveProfile(p.name), 'activate') : null,
                            child: Row(children: [
                              _Radio(on: p.active, disabled: !p.hasKey),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Flexible(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(14, weight: FontWeight.w600, color: AppColors.fg1))),
                                    if (!p.hasKey) ...[const SizedBox(width: 8), const WarnChip()],
                                    if (p.active) ...[const SizedBox(width: 8), Text('ACTIVE', style: sans(10, weight: FontWeight.w500, spacing: 0.4, color: AppColors.accent))],
                                  ]),
                                  const SizedBox(height: 4),
                                  Text('${p.provider} · ${p.model}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11.5, color: AppColors.fg3)),
                                ]),
                              ),
                              IconBtn('edit', size: 34, iconSize: 16, onTap: () => _edit(p)),
                              IconBtn('trash', size: 34, iconSize: 16, onTap: () => _run(() => widget.client.deleteProfile(p.name), 'delete')),
                            ]),
                          ),
                        )),
                    AddCard(label: 'Add model', onTap: () => _edit(null)),
                  ],
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  final bool on, disabled;
  const _Radio({required this.on, required this.disabled});
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: on ? AppColors.accent : AppColors.border2, width: 2),
        ),
        child: on
            ? Center(child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle)))
            : null,
      ),
    );
  }
}
