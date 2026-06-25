import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'folder_browser.dart';
import 'session.dart';

/// Sessions for one instance: attach to an existing one, or open a new folder.
class SessionsScreen extends StatefulWidget {
  final DaemonClient client;
  final String instanceName;
  const SessionsScreen({
    super.key,
    required this.client,
    required this.instanceName,
  });

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late Future<List<SessionInfo>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.client.sessions();
  }

  void _refresh() => setState(() => _future = widget.client.sessions());

  Future<void> _openSession(String id, String title) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            SessionScreen(client: widget.client, sessionId: id, title: title),
      ),
    );
    _refresh();
  }

  Future<void> _newSession() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FolderBrowser(client: widget.client)),
    );
    if (id != null && mounted) {
      await _openSession(id, 'new session');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.instanceName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newSession,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Open folder'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<List<SessionInfo>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _ErrorView(message: '${snap.error}', onRetry: _refresh);
            }
            final sessions = snap.data ?? const [];
            if (sessions.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 140),
                  Center(
                    child: Column(
                      children: [
                        Icon(Icons.folder_open_outlined,
                            size: 40, color: Theme.of(context).hintColor),
                        const SizedBox(height: 12),
                        const Text('No sessions yet'),
                        const SizedBox(height: 4),
                        Text(
                          'Tap “Open folder” to start one.',
                          style: TextStyle(color: Theme.of(context).hintColor),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: sessions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = sessions[i];
                return ListTile(
                  leading: Icon(
                    s.running ? Icons.bolt : Icons.folder_outlined,
                    color: s.running ? Colors.amber : null,
                  ),
                  title: Text(
                    s.title.isEmpty ? '(untitled)' : s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    s.folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    s.status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () => _openSession(s.id, s.title),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
