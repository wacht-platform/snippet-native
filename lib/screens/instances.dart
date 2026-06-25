import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../store.dart';
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
      appBar: AppBar(title: const Text('Instances')),
      floatingActionButton: (instances != null && instances.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            )
          : null,
      body: instances == null
          ? const Center(child: CircularProgressIndicator())
          : instances.isEmpty
              ? _Empty(onAdd: _add)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: instances.length,
                  itemBuilder: (_, i) {
                    final inst = instances[i];
                    return Dismissible(
                      key: ValueKey('${inst.url}|${inst.token}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 22),
                        child: const Icon(Icons.delete_outline),
                      ),
                      onDismissed: (_) => _remove(inst),
                      child: Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          leading: _StatusDot(
                            client: DaemonClient(inst.url, inst.token),
                          ),
                          title: Text(
                            inst.label,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16),
                          ),
                          subtitle: Text(
                            hostOf(inst.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(inst),
                        ),
                      ),
                    );
                  },
                ),
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
            Icon(Icons.dns_outlined, size: 56, color: Theme.of(context).hintColor),
            const SizedBox(height: 16),
            const Text('No instances yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'Run `snippet serve` and add the connection string it prints.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add instance'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A health dot: grey while checking, green if the daemon answers, red if not.
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
        ? Theme.of(context).hintColor
        : (_online! ? Colors.greenAccent : Colors.redAccent);
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.circle, size: 12, color: color),
    );
  }
}
