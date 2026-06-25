import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'add_instance.dart';
import 'sessions.dart';

/// Home screen: all connected daemon instances. Pick one to manage its sessions.
class InstancesScreen extends StatefulWidget {
  const InstancesScreen({super.key});

  @override
  State<InstancesScreen> createState() => _InstancesScreenState();
}

class _InstancesScreenState extends State<InstancesScreen> {
  final _store = InstanceStore();
  List<Instance>? _instances;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _store.load();
    if (mounted) setState(() => _instances = items);
  }

  Future<void> _add() async {
    final inst = await Navigator.push<Instance>(
      context,
      MaterialPageRoute(builder: (_) => const AddInstanceScreen()),
    );
    if (inst == null) return;
    final items = [...?_instances]..removeWhere((e) => e.url == inst.url);
    items.add(inst);
    await _store.save(items);
    if (mounted) setState(() => _instances = items);
  }

  Future<void> _remove(Instance inst) async {
    final items = [...?_instances]
      ..removeWhere((e) => e.url == inst.url && e.token == inst.token);
    await _store.save(items);
    if (mounted) setState(() => _instances = items);
  }

  void _open(Instance inst) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionsScreen(
          client: DaemonClient(inst.url, inst.token),
          instanceName: inst.label,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final instances = _instances;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instances'),
        bottom: const _AppBarSubtitle('Your snippet daemons'),
      ),
      floatingActionButton: (instances != null && instances.isNotEmpty)
          ? GradientButton(
              icon: Icons.add,
              label: 'Add',
              onTap: _add,
              compact: true,
            )
          : null,
      body: instances == null
          ? const Center(child: CircularProgressIndicator())
          : instances.isEmpty
              ? _Empty(onAdd: _add)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: instances.length,
                  itemBuilder: (_, i) {
                    final inst = instances[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Dismissible(
                        key: ValueKey('${inst.url}|${inst.token}'),
                        direction: DismissDirection.endToStart,
                        background: _DismissBg(),
                        onDismissed: (_) => _remove(inst),
                        child: GlassCard(
                          onTap: () => _open(inst),
                          child: Row(
                            children: [
                              _StatusDot(
                                  client: DaemonClient(inst.url, inst.token)),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      inst.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      hostOf(inst.url),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: AppColors.muted, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right,
                                  color: AppColors.muted),
                            ],
                          ),
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 280.ms, delay: (40 * i).ms)
                        .slideY(begin: 0.08, curve: Curves.easeOut);
                  },
                ),
    );
  }
}

class _AppBarSubtitle extends StatelessWidget implements PreferredSizeWidget {
  final String text;
  const _AppBarSubtitle(this.text);
  @override
  Size get preferredSize => const Size.fromHeight(22);
  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(text,
          style: const TextStyle(color: AppColors.muted, fontSize: 13)),
    );
  }
}

class _DismissBg extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.offline.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(18),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 22),
      child: const Icon(Icons.delete_outline, color: AppColors.offline),
    );
  }
}

class _Empty extends StatelessWidget {
  final VoidCallback onAdd;
  const _Empty({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  AppColors.accent.withValues(alpha: 0.18),
                  AppColors.accent2.withValues(alpha: 0.18),
                ]),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.dns_outlined,
                  size: 40, color: AppColors.accent),
            ),
            const SizedBox(height: 20),
            const Text('No instances yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
              'Run `snippet serve` and add the connection string it prints.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 24),
            GradientButton(icon: Icons.add, label: 'Add instance', onTap: onAdd),
          ],
        ),
      ).animate().fadeIn(duration: 400.ms),
    );
  }
}

/// Health dot: muted while checking, green online, red offline.
class _StatusDot extends StatefulWidget {
  final DaemonClient client;
  const _StatusDot({required this.client});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> {
  bool? _online;

  @override
  void initState() {
    super.initState();
    widget.client.health().then((v) {
      if (mounted) setState(() => _online = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _online == null
        ? AppColors.muted
        : (_online! ? AppColors.online : AppColors.offline);
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: GlowDot(color: color),
    );
  }
}
