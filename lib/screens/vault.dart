import 'package:flutter/material.dart';

import '../api.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets.dart';

/// Secret vault — names only ever reach this screen (and the agent); values go
/// straight to the daemon on save and are injected/redacted server-side.
class VaultScreen extends StatefulWidget {
  final DaemonClient client;
  final VoidCallback? onClose;
  const VaultScreen({super.key, required this.client, this.onClose});
  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  late Future<List<String>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.client.vaultList();
  }

  void _refresh() {
    if (mounted) setState(() => _future = widget.client.vaultList());
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final value = TextEditingController();
    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(R.sheetTop))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 18, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Add secret', style: sans(16, color: AppColors.fg1)),
          const SizedBox(height: 14),
          AppField(label: 'Name', controller: name, mono: true, hint: 'STRIPE_KEY — env-var style (A-Z, 0-9, _)'),
          const SizedBox(height: 12),
          AppField(label: 'Value', controller: value, mono: true, obscure: true, hint: 'stored on the daemon, never shown again'),
          const SizedBox(height: 16),
          Btn('Save', full: true, onTap: () => Navigator.pop(ctx, true)),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (saved != true) return;
    final n = name.text.trim().toUpperCase();
    final v = value.text;
    if (n.isEmpty || v.trim().isEmpty) return;
    try {
      await widget.client.vaultSet(n, v);
      _refresh();
    } catch (e) {
      if (mounted) toast(context, '$e', danger: true);
    }
  }

  Future<void> _remove(String name) async {
    try {
      await widget.client.vaultDelete(name);
      _refresh();
    } catch (e) {
      if (mounted) toast(context, '$e', danger: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: 'Vault', onBack: widget.onClose ?? () => Navigator.pop(context)),
          Expanded(
            child: FutureBuilder<List<String>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)));
                }
                final names = snap.data ?? const [];
                final list = ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    const SectionLabel('Secrets'),
                    const SizedBox(height: 6),
                    Text(
                      'The agent can use these as \$NAME in shell commands. Values are injected into the process and redacted from everything the model sees — they never appear in chat.',
                      style: sans(11.5, height: 1.4, color: AppColors.fg3),
                    ),
                    const SizedBox(height: 12),
                    if (names.isEmpty) ...[
                      const EmptyState(icon: 'key', title: 'No secrets', body: 'Add API keys or tokens the agent may use in shell commands without ever seeing them.'),
                      const SizedBox(height: 10),
                    ],
                    ...names.map(_secretRow),
                    const SizedBox(height: 2),
                    AddCard(label: 'Add secret', onTap: _add),
                  ],
                );
                return kMobile ? list : Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: list));
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _secretRow(String name) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.surface2, borderRadius: BorderRadius.circular(R.sm)),
            child: const AppIcon('key', size: 16, color: AppColors.fg3),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(name, style: mono(13.5, color: AppColors.fg1))),
          Text('••••••', style: mono(12, color: AppColors.fg4)),
          const SizedBox(width: 4),
          IconBtn('trash', size: 34, iconSize: 16, onTap: () => _remove(name)),
        ]),
      ),
    );
  }
}
