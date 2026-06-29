import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor.dart';

/// Standalone file browser — navigate folders and view file contents on a
/// connected machine without opening an agent session.
class FileExplorer extends StatefulWidget {
  final DaemonClient client;
  final String title;
  const FileExplorer({super.key, required this.client, this.title = 'Files'});
  @override
  State<FileExplorer> createState() => _FileExplorerState();
}

class _FileExplorerState extends State<FileExplorer> {
  late Future<FsListing> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.client.fs(null);
  }

  void _go(String? path) => setState(() => _future = widget.client.fs(path));

  void _openFile(FsEntry e) => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FileViewer(client: widget.client, path: e.path, name: e.name)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<FsListing>(
          future: _future,
          builder: (context, snap) {
            final listing = snap.data;
            final segs = (listing?.path ?? '').split('/').where((s) => s.isNotEmpty).toList();
            return Column(children: [
              SnAppBar(title: widget.title, subtitle: listing?.path, onBack: () => Navigator.pop(context)),
              if (segs.isNotEmpty)
                Container(
                  height: 40,
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      Text('/', style: mono(11.5, color: AppColors.fg4)),
                      for (var i = 0; i < segs.length; i++) ...[
                        if (i > 0) const Padding(padding: EdgeInsets.symmetric(horizontal: 2), child: AppIcon('chevron-right', size: 13, color: AppColors.fg4)),
                        Text(segs[i], style: mono(11.5, color: i == segs.length - 1 ? AppColors.fg1 : AppColors.fg3)),
                      ],
                    ]),
                  ),
                ),
              Expanded(
                child: snap.connectionState == ConnectionState.waiting
                    ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)))
                    : snap.hasError
                        ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center, style: sans(12.5, color: AppColors.fg3))))
                        : ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            children: [
                              if (listing!.parent != null)
                                _Row(icon: 'folder-open', name: '..', muted: true, onTap: () => _go(listing.parent)),
                              ...listing.entries.map((e) => _Row(
                                    icon: e.isDir ? 'folder' : 'file',
                                    name: e.name,
                                    git: e.git,
                                    chevron: e.isDir,
                                    onTap: e.isDir ? () => _go(e.path) : () => _openFile(e),
                                  )),
                            ],
                          ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String icon, name;
  final bool git, muted, chevron;
  final VoidCallback? onTap;
  const _Row({required this.icon, required this.name, this.git = false, this.muted = false, this.chevron = false, this.onTap});
  @override
  Widget build(BuildContext context) {
    final isFile = icon == 'file';
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            AppIcon(icon, size: 18, color: isFile ? AppColors.fg3 : AppColors.accent),
            const SizedBox(width: 11),
            Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(13, color: muted ? AppColors.fg3 : AppColors.fg1))),
            if (git) ...[
              const AppIcon('git-branch', size: 12, color: AppColors.ok),
              const SizedBox(width: 4),
              Text('git', style: mono(10.5, color: AppColors.fg3)),
              const SizedBox(width: 8),
            ],
            if (chevron) const AppIcon('chevron-right', size: 16, color: AppColors.fg4),
          ]),
        ),
      ),
    );
  }
}

/// Read-only viewer for one file.
class FileViewer extends StatefulWidget {
  final DaemonClient client;
  final String path;
  final String name;
  const FileViewer({super.key, required this.client, required this.path, required this.name});
  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  late Future<FileContent> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.client.readFile(widget.path);
  }

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: widget.name, subtitle: widget.path, onBack: () => Navigator.pop(context), actions: [
            IconBtn('edit', tooltip: 'Edit', onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => EditorScreen(client: widget.client, path: widget.path, name: widget.name),
            )).then((_) => setState(() => _future = widget.client.readFile(widget.path)))),
          ]),
          Expanded(
            child: FutureBuilder<FileContent>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3)));
                }
                if (snap.hasError) {
                  return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center, style: sans(12.5, color: AppColors.fg3))));
                }
                final f = snap.data!;
                if (f.binary) {
                  return EmptyState(icon: 'file', title: 'Binary file', body: '${_bytes(f.size)} — can\'t display as text.');
                }
                final lines = f.content.split('\n');
                final gw = '${lines.length}'.length * 8.0 + 8;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
                    child: Text('${lines.length} lines · ${_bytes(f.size)}${f.truncated ? ' · truncated' : ''}',
                        style: mono(10.5, color: AppColors.fg4)),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      primary: true,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            for (var i = 0; i < lines.length; i++)
                              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                SizedBox(width: gw, child: Text('${i + 1}', textAlign: TextAlign.right, style: mono(11.5, height: 1.5, color: AppColors.diffGutter))),
                                const SizedBox(width: 10),
                                Text(lines[i].isEmpty ? ' ' : lines[i], style: mono(11.5, height: 1.5, color: AppColors.fg1)),
                              ]),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ]);
              },
            ),
          ),
        ]),
      ),
    );
  }
}
