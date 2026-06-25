import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';

/// Lazily browse the daemon host's filesystem (GET /fs) and open a folder as a
/// session (POST /sessions). Pops the chosen session id back to the caller.
class FolderBrowser extends StatefulWidget {
  final DaemonClient client;
  const FolderBrowser({super.key, required this.client});

  @override
  State<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<FolderBrowser> {
  late Future<FsListing> _future;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _future = widget.client.fs(null);
  }

  void _go(String? path) => setState(() => _future = widget.client.fs(path));

  Future<void> _open(String folder) async {
    setState(() => _opening = true);
    try {
      final id = await widget.client.openSession(folder);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() => _opening = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FsListing>(
      future: _future,
      builder: (context, snap) {
        final listing = snap.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              listing?.path ?? 'Choose folder',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          bottomNavigationBar: listing == null
              ? null
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _opening ? null : () => _open(listing.path),
                    icon: _opening
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.play_arrow),
                    label: Text(_opening ? 'Opening…' : 'Open this folder'),
                  ),
                ),
          body: switch (snap) {
            AsyncSnapshot(connectionState: ConnectionState.waiting) =>
              const Center(child: CircularProgressIndicator()),
            AsyncSnapshot(hasError: true) =>
              Center(child: Text('${snap.error}')),
            _ => ListView(
                children: [
                  if (listing!.parent != null)
                    ListTile(
                      leading: const Icon(Icons.arrow_upward),
                      title: const Text('..'),
                      onTap: () => _go(listing.parent),
                    ),
                  ...listing.entries.map(
                    (e) => ListTile(
                      leading: Icon(
                        e.isDir
                            ? (e.git ? Icons.source : Icons.folder)
                            : Icons.insert_drive_file_outlined,
                        color: e.git ? Colors.greenAccent : null,
                      ),
                      title: Text(e.name),
                      trailing: e.git ? const Text('git') : null,
                      enabled: e.isDir,
                      onTap: e.isDir ? () => _go(e.path) : null,
                    ),
                  ),
                ],
              ),
          },
        );
      },
    );
  }
}
