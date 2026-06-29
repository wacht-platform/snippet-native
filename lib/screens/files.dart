import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../api.dart';
import '../highlight.dart';
import '../models.dart';
import '../panel.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor.dart';

/// Standalone file browser — navigate folders and view file contents on a
/// connected machine without opening an agent session.
class FileExplorer extends StatefulWidget {
  final DaemonClient client;
  final String title;
  final String? start; // initial folder (null = the daemon's home dir)
  final VoidCallback? onClose; // dismiss when hosted in a desktop panel
  const FileExplorer({super.key, required this.client, this.title = 'Files', this.start, this.onClose});
  @override
  State<FileExplorer> createState() => _FileExplorerState();
}

class _FileExplorerState extends State<FileExplorer> {
  late Future<FsListing> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.client.fs(widget.start);
  }

  void _go(String? path) => setState(() { _future = widget.client.fs(path); });

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
              SnAppBar(title: widget.title, subtitle: listing?.path, onBack: widget.onClose ?? () => Navigator.pop(context)),
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
  final CodeLineEditingController _controller = CodeLineEditingController();
  FileContent? _f;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final f = await widget.client.readFile(widget.path);
      if (!mounted) return;
      if (!f.binary) _controller.text = f.content;
      setState(() {
        _f = f;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final f = _f;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: widget.name, subtitle: widget.path, onBack: () => Navigator.pop(context), actions: [
            IconBtn('edit', tooltip: 'Edit', onTap: () => presentScreen(context,
              style: PanelStyle.dialog,
              dismissible: false,
              builder: (_, close) => EditorScreen(client: widget.client, path: widget.path, name: widget.name, onClose: close),
            ).then((_) => _load())),
          ]),
          if (_loading)
            const Expanded(child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))))
          else if (_error != null)
            Expanded(child: EmptyState(icon: 'alert-triangle', title: 'Failed to load', body: _error!))
          else if (f!.binary)
            Expanded(child: EmptyState(icon: 'file', title: 'Binary file', body: '${_bytes(f.size)} — can\'t display as text.'))
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
              child: Text('${f.content.split('\n').length} lines · ${_bytes(f.size)}${f.truncated ? ' · truncated' : ''}',
                  style: mono(10.5, color: AppColors.fg4)),
            ),
            Expanded(
              child: CodeEditor(
                controller: _controller,
                readOnly: true,
                wordWrap: false,
                style: codeEditorStyle(widget.name),
                indicatorBuilder: (context, editingController, chunkController, notifier) {
                  return Row(children: [
                    DefaultCodeLineNumber(controller: editingController, notifier: notifier),
                    DefaultCodeChunkIndicator(width: 20, controller: chunkController, notifier: notifier),
                  ]);
                },
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
