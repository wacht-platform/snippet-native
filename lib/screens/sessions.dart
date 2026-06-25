import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
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
      floatingActionButton: GradientButton(
        icon: Icons.create_new_folder_outlined,
        label: 'Open folder',
        onTap: _newSession,
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        color: AppColors.accent,
        backgroundColor: AppColors.surface,
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
              return _empty(context);
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: sessions.length,
              itemBuilder: (context, i) {
                final s = sessions[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GlassCard(
                    onTap: () => _openSession(s.id, s.title),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: (s.running ? AppColors.running : AppColors.muted)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            s.running ? Icons.bolt : Icons.folder_outlined,
                            color: s.running ? AppColors.running : AppColors.muted,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.title.isEmpty ? '(untitled)' : s.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s.folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppColors.muted, fontSize: 12.5),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Pill(
                          text: s.status.isEmpty ? '—' : s.status,
                          color: s.running ? AppColors.running : AppColors.muted,
                        ),
                      ],
                    ),
                  ),
                )
                    .animate()
                    .fadeIn(duration: 260.ms, delay: (40 * i).ms)
                    .slideY(begin: 0.08, curve: Curves.easeOut);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 130),
        Center(
          child: Column(
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.folder_open_outlined,
                    size: 36, color: AppColors.accent),
              ),
              const SizedBox(height: 16),
              const Text('No sessions yet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('Tap “Open folder” to start one.',
                  style: TextStyle(color: AppColors.muted)),
            ],
          ),
        ),
      ],
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
            const Icon(Icons.cloud_off_outlined, size: 44, color: AppColors.muted),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
