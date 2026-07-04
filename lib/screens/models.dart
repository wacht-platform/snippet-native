import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../panel.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets.dart';
import 'model_editor.dart';

class ModelsScreen extends StatefulWidget {
  final DaemonClient client;
  final VoidCallback? onClose;
  const ModelsScreen({super.key, required this.client, this.onClose});
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

  void _refresh() {
    if (!mounted) return;
    setState(() { _future = widget.client.getConfig(); });
  }

  Future<void> _run(Future<void> Function() op, String onError) async {
    try {
      await op();
      _refresh();
    } catch (e) {
      if (mounted) toast(context, '$onError: $e', danger: true);
    }
  }

  Future<void> _edit(ModelProfile? p) async {
    final saved = await presentScreen<bool>(
      context,
      builder: (_, close) => ModelEditorScreen(client: widget.client, existing: p, onClose: close),
    );
    if (saved == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: 'Models', onBack: widget.onClose ?? () => Navigator.pop(context)),
          Expanded(
            child: FutureBuilder<ServerConfig>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)));
                }
                final profiles = snap.data?.profiles ?? const [];
                final list = ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    const SectionLabel('Model profiles'),
                    const SizedBox(height: 10),
                    if (profiles.isEmpty) ...[
                      const EmptyState(icon: 'cpu', title: 'No model configured', body: 'Add a model profile with an API key before starting a session.'),
                      const SizedBox(height: 10),
                    ],
                    ...profiles.map(_profileCard),
                    const SizedBox(height: 2),
                    AddCard(label: 'Add model', onTap: () => _edit(null)),
                  ],
                );
                // Don't stretch full-width on desktop — keep a readable column.
                return kMobile ? list : Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: list));
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _profileCard(ModelProfile p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        onTap: p.usable ? () => _run(() => widget.client.setActiveProfile(p.name), 'activate') : null,
        padding: const EdgeInsets.fromLTRB(12, 11, 6, 11),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.active ? AppColors.accentBg : AppColors.surface2,
              borderRadius: BorderRadius.circular(R.md),
            ),
            child: AppIcon('cpu', size: 18, color: p.active ? AppColors.accent : AppColors.fg3),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(14, color: AppColors.fg1))),
                if (p.active) ...[const SizedBox(width: 8), _activeChip()],
                if (!p.usable) ...[const SizedBox(width: 8), const WarnChip()],
              ]),
              const SizedBox(height: 4),
              Text('${p.provider} · ${p.model}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11.5, color: AppColors.fg3)),
            ]),
          ),
          IconBtn('edit', size: 34, iconSize: 16, onTap: () => _edit(p)),
          IconBtn('trash', size: 34, iconSize: 16, onTap: () => _run(() => widget.client.deleteProfile(p.name), 'delete')),
        ]),
      ),
    );
  }

  Widget _activeChip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: AppColors.accentBg, borderRadius: BorderRadius.circular(R.xs)),
        child: Text('ACTIVE', style: sans(9.5, spacing: 0.5, color: AppColors.accent)),
      );
}
