import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../notifications.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'add_instance.dart';
import 'recent.dart';

class InstancesScreen extends StatefulWidget {
  const InstancesScreen({super.key});
  @override
  State<InstancesScreen> createState() => _InstancesScreenState();
}

class _InstancesScreenState extends State<InstancesScreen> {
  final _store = InstanceStore();
  List<Instance>? _instances;
  bool _edit = false;

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
        context, MaterialPageRoute(builder: (_) => const AddInstanceScreen()));
    if (inst == null) return;
    final items = [...?_instances]..removeWhere((e) => e.url == inst.url);
    items.add(inst);
    await _store.save(items);
    if (mounted) setState(() => _instances = items);
  }

  Future<void> _remove(int i) async {
    final items = [...?_instances]..removeAt(i);
    await _store.save(items);
    if (mounted) setState(() => _instances = items);
  }

  Future<void> _move(int i, int dir) async {
    final j = i + dir;
    final items = [...?_instances];
    if (j < 0 || j >= items.length) return;
    final t = items[i];
    items[i] = items[j];
    items[j] = t;
    await _store.save(items);
    if (mounted) setState(() => _instances = items);
  }

  void _open(Instance inst) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => RecentSessionsScreen(
                client: DaemonClient(inst.url, inst.token), instance: inst)));
  }

  void _showSettings() {
    showAppSheet(context, title: 'Settings', child: StatefulBuilder(
      builder: (ctx, setSheet) => FutureBuilder<bool>(
        future: notificationsEnabled(),
        builder: (_, snap) {
          final on = snap.data ?? false;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppToggle(
              on: on,
              label: 'Background notifications',
              sub: 'Get pinged when a session needs you, even with the app in the background.',
              onChanged: (v) async {
                final err = await setNotificationsEnabled(v);
                if (err != null && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                }
                setSheet(() {});
              },
            ),
            const SizedBox(height: 12),
            Text(
              'Keeps a lightweight watcher running with a persistent notification. On Android 15 background watching may pause after a few hours until you reopen the app, and it cannot notify after you force-stop the app.',
              style: sans(11.5, height: 1.45, color: AppColors.fg3),
            ),
          ]);
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final instances = _instances;
    final empty = instances != null && instances.isEmpty;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: 'Instances', actions: [
            IconBtn('settings', onTap: _showSettings),
            if (instances != null && !empty)
              GestureDetector(
                onTap: () => setState(() => _edit = !_edit),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(_edit ? 'Done' : 'Edit',
                      style: sans(13,
                          weight: FontWeight.w500,
                          color: _edit ? AppColors.accent : AppColors.fg2)),
                ),
              ),
          ]),
          Expanded(
            child: instances == null
                ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                    children: [
                      if (empty) ...[
                        const EmptyState(
                          icon: 'cpu',
                          title: 'No instances yet',
                          body: 'Connect to a machine running snippet serve to start coding from your phone.',
                        ),
                        const SizedBox(height: 8),
                      ],
                      ...instances.asMap().entries.map((e) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _InstanceCard(
                              key: ValueKey('${e.value.url}|${e.value.token}'),
                              instance: e.value,
                              edit: _edit,
                              first: e.key == 0,
                              last: e.key == instances.length - 1,
                              onOpen: () => _open(e.value),
                              onUp: () => _move(e.key, -1),
                              onDown: () => _move(e.key, 1),
                              onRemove: () => _remove(e.key),
                            ),
                          )),
                      AddCard(label: 'Add instance', onTap: _add),
                    ],
                  ),
          ),
        ]),
      ),
    );
  }
}

class _InstanceCard extends StatefulWidget {
  final Instance instance;
  final bool edit, first, last;
  final VoidCallback onOpen, onUp, onDown, onRemove;
  const _InstanceCard({
    super.key,
    required this.instance,
    required this.edit,
    required this.first,
    required this.last,
    required this.onOpen,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });
  @override
  State<_InstanceCard> createState() => _InstanceCardState();
}

class _InstanceCardState extends State<_InstanceCard> {
  String _status = 'checking';

  @override
  void initState() {
    super.initState();
    _check();
  }

  void _check() {
    setState(() => _status = 'checking');
    DaemonClient(widget.instance.url, widget.instance.token).health().then((ok) {
      if (mounted) setState(() => _status = ok ? 'online' : 'offline');
    });
  }

  @override
  Widget build(BuildContext context) {
    final inst = widget.instance;
    final offline = _status == 'offline';
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      onTap: widget.edit || offline ? null : widget.onOpen,
      child: Row(children: [
        if (widget.edit)
          Column(mainAxisSize: MainAxisSize.min, children: [
            Opacity(opacity: widget.first ? 0.3 : 1, child: IconBtn('chevron-up', size: 22, iconSize: 15, onTap: widget.onUp)),
            Opacity(opacity: widget.last ? 0.3 : 1, child: IconBtn('chevron-down', size: 22, iconSize: 15, onTap: widget.onDown)),
          ])
        else
          StatusDot(status: _status),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(inst.label, style: sans(13.5, weight: FontWeight.w600, color: AppColors.fg1)),
            const SizedBox(height: 2),
            Text(hostOf(inst.url), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5, color: AppColors.fg3)),
            if (offline && !widget.edit)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: GestureDetector(
                  onTap: _check,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const AppIcon('refresh', size: 12, color: AppColors.accent),
                    const SizedBox(width: 5),
                    Text('Reconnect', style: sans(11.5, weight: FontWeight.w500, color: AppColors.accent)),
                  ]),
                ),
              ),
          ]),
        ),
        if (widget.edit)
          IconBtn('trash', size: 32, iconSize: 16, onTap: widget.onRemove)
        else if (offline)
          const AppIcon('wifi-off', size: 16, color: AppColors.danger)
        else
          const AppIcon('chevron-right', size: 16, color: AppColors.fg4),
      ]),
    );
  }
}
