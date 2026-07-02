import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:re_editor/re_editor.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../highlight.dart';
import '../models.dart';
import '../panel.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets.dart';
import 'editor.dart';
import 'git.dart';

/// Standalone file browser — navigate folders and view file contents on a
/// connected machine without opening an agent session.
class FileExplorer extends StatefulWidget {
  final DaemonClient client;
  final String title;
  final String? start; // initial folder (null = the daemon's home dir)
  final VoidCallback? onClose; // dismiss when hosted in a desktop panel
  final void Function(String folder)? onNewChat; // start a chat in the current folder
  const FileExplorer({super.key, required this.client, this.title = 'Files', this.start, this.onClose, this.onNewChat});
  @override
  State<FileExplorer> createState() => _FileExplorerState();
}

class _FileExplorerState extends State<FileExplorer> {
  late Future<FsListing> _future;
  bool _selecting = false;
  final Set<String> _selected = {};
  String? _busy; // non-null while uploading/deleting (label shown in a progress strip)

  @override
  void initState() {
    super.initState();
    _future = widget.client.fs(widget.start);
  }

  void _go(String? path) => setState(() {
        _future = widget.client.fs(path);
        _selecting = false;
        _selected.clear();
      });

  void _toggle(FsEntry e) => setState(() {
        if (!_selected.remove(e.path)) _selected.add(e.path);
        if (_selected.isEmpty) _selecting = false;
      });

  void _enterSelect(FsEntry e) => setState(() {
        _selecting = true;
        _selected.add(e.path);
      });

  void _exitSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _deleteSelected(String cwd) async {
    final n = _selected.length;
    if (n == 0) return;
    final ok = await showAppSheet<bool>(context, title: 'Delete $n item${n == 1 ? '' : 's'}?', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Permanently deletes the selected item${n == 1 ? '' : 's'} from the machine. Folders are removed with their contents.', style: sans(12, height: 1.45, color: AppColors.fg3)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Btn('Cancel', variant: BtnVariant.secondary, onTap: () => Navigator.pop(context, false))),
          const SizedBox(width: 10),
          Expanded(child: Btn('Delete', variant: BtnVariant.danger, icon: 'trash', onTap: () => Navigator.pop(context, true))),
        ]),
      ],
    ));
    if (ok != true) return;
    if (mounted) setState(() => _busy = 'Deleting $n item${n == 1 ? '' : 's'}…');
    var failed = 0;
    for (final p in _selected.toList()) {
      try {
        await widget.client.deletePath(p);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _busy = null);
    if (failed > 0) toast(context, 'Failed to delete $failed item(s)', danger: true);
    _go(cwd); // refresh + clears selection
  }

  Future<void> _newFolder(String cwd) async {
    final name = await promptText(context, title: 'New folder', hint: 'Folder name', saveLabel: 'Create');
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      await widget.client.mkdir('$cwd/$trimmed');
      if (!mounted) return;
      _go(cwd);
    } catch (e) {
      if (mounted) toast(context, '$e', danger: true);
    }
  }

  // Upload files from the device into the current directory.
  Future<void> _upload(String cwd) async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true, type: FileType.any);
    } catch (e) {
      if (mounted) toast(context, '$e', danger: true);
      return;
    }
    if (res == null) return;
    final files = res.files;
    var uploaded = 0;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      if (mounted) setState(() => _busy = 'Uploading ${i + 1}/${files.length}…');
      try {
        final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
        if (bytes == null) continue;
        await widget.client.uploadFile(bytes, name: f.name, dir: cwd);
        uploaded++;
      } catch (e) {
        if (mounted) toast(context, '${f.name}: $e', danger: true);
      }
    }
    if (!mounted) return;
    setState(() => _busy = null);
    if (uploaded > 0) {
      _go(cwd);
      toast(context, 'Uploaded $uploaded file${uploaded == 1 ? '' : 's'}');
    }
  }

  void _openFile(FsEntry e) => presentScreen(
        context,
        builder: (_, close) => FileViewer(client: widget.client, path: e.path, name: e.name, onClose: close),
      );

  // Git for the current folder directly — no session required (the daemon runs
  // git in that directory; non-repos show a "No git here" message).
  void _openGit(String dir) => presentScreen(
        context,
        builder: (_, close) => GitScreen(client: widget.client, folder: dir, onClose: close),
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
              SnAppBar(
                title: _selecting ? '${_selected.length} selected' : widget.title,
                subtitle: _selecting ? null : listing?.path,
                onBack: _selecting ? _exitSelect : (widget.onClose ?? () => Navigator.pop(context)),
                actions: _selecting
                    ? [
                        IconBtn('trash', tooltip: 'Delete', onTap: (_busy != null || listing == null || _selected.isEmpty) ? null : () => _deleteSelected(listing.path)),
                        IconBtn('x', tooltip: 'Cancel', onTap: _exitSelect),
                      ]
                    : [
                        if (listing != null) IconBtn('git-branch', tooltip: 'Git', onTap: () => _openGit(listing.path)),
                        if (listing != null) IconBtn('upload', tooltip: 'Upload files', onTap: _busy != null ? null : () => _upload(listing.path)),
                        if (listing != null) IconBtn('folder-plus', tooltip: 'New folder', onTap: _busy != null ? null : () => _newFolder(listing.path)),
                      ],
              ),
              // Prominent CTA: start a chat in the folder you're browsing (no session needed).
              if (!_selecting && listing != null && widget.onNewChat != null)
                Material(
                  color: AppColors.accentBg,
                  child: InkWell(
                    onTap: () => widget.onNewChat!(listing.path),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
                      child: Row(children: [
                        const AppIcon('edit', size: 16, color: AppColors.accent),
                        const SizedBox(width: 10),
                        Expanded(child: Text('New chat in this folder', style: sans(13.5, weight: FontWeight.w600, color: AppColors.accent))),
                        const AppIcon('arrow-right', size: 15, color: AppColors.accent),
                      ]),
                    ),
                  ),
                ),
              if (_busy != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
                  child: Row(children: [
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
                    const SizedBox(width: 10),
                    Text(_busy!, style: sans(12, color: AppColors.fg2)),
                  ]),
                ),
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
                              if (listing!.parent != null && !_selecting)
                                _Row(icon: 'folder-open', name: '..', muted: true, onTap: () => _go(listing.parent)),
                              ...listing.entries.map((e) => _Row(
                                    icon: e.isDir ? 'folder' : 'file',
                                    name: e.name,
                                    git: e.git,
                                    chevron: e.isDir && !_selecting,
                                    selecting: _selecting,
                                    selected: _selected.contains(e.path),
                                    onTap: _selecting ? () => _toggle(e) : (e.isDir ? () => _go(e.path) : () => _openFile(e)),
                                    onLongPress: () => _selecting ? _toggle(e) : _enterSelect(e),
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
  final bool git, muted, chevron, selecting, selected;
  final VoidCallback? onTap, onLongPress;
  const _Row({
    required this.icon,
    required this.name,
    this.git = false,
    this.muted = false,
    this.chevron = false,
    this.selecting = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
  });
  @override
  Widget build(BuildContext context) {
    final isFile = icon == 'file';
    return Material(
      color: selected ? AppColors.accentBg : Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(R.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            if (selecting) ...[_checkbox(selected), const SizedBox(width: 11)],
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

  Widget _checkbox(bool on) => Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? AppColors.accent : Colors.transparent,
          border: Border.all(color: on ? AppColors.accent : AppColors.border2, width: 1.5),
        ),
        child: on ? const Icon(Icons.check_rounded, size: 12, color: AppColors.accentFg) : null,
      );
}

/// Read-only viewer for one file.
class FileViewer extends StatefulWidget {
  final DaemonClient client;
  final String path;
  final String name;
  final VoidCallback? onClose;
  const FileViewer({super.key, required this.client, required this.path, required this.name, this.onClose});
  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  final CodeLineEditingController _controller = CodeLineEditingController();
  FileContent? _f;
  bool _loading = true;
  bool _downloading = false;
  String? _error;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final bytes = await widget.client.downloadFile(widget.path);
      // Keep the original extension so the OS recognizes the file type (e.g. .docx,
      // not a generic binary).
      final dot = widget.name.lastIndexOf('.');
      final ext = dot > 0 ? widget.name.substring(dot + 1).toLowerCase() : '';
      String? message;
      if (kMobile) {
        // Android/iOS: the system document picker doesn't reliably keep the
        // extension. Write the bytes to a temp file with the real name and hand
        // it to the share/save sheet, which preserves the filename.
        final tmp = File('${(await getTemporaryDirectory()).path}/${widget.name}');
        await tmp.writeAsBytes(bytes);
        final res = await Share.shareXFiles([XFile(tmp.path, name: widget.name)]);
        message = res.status == ShareResultStatus.success ? 'Saved ${widget.name}' : null;
      } else {
        // Desktop: the save panel returns a path (no write); write the bytes
        // ourselves and re-append the extension if the panel dropped it.
        final saved = await FilePicker.platform.saveFile(fileName: widget.name);
        if (saved != null) {
          final out = (ext.isNotEmpty && !saved.toLowerCase().endsWith('.$ext')) ? '$saved.$ext' : saved;
          await File(out).writeAsBytes(bytes);
          message = 'Downloaded ${widget.name}';
        }
      }
      if (!mounted) return;
      setState(() => _downloading = false);
      if (message != null) toast(context, message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading = false);
      toast(context, '$e', danger: true);
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final f = _f;
    return Scaffold(
      backgroundColor: readingBg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          SnAppBar(title: widget.name, subtitle: widget.path, onBack: widget.onClose ?? () => Navigator.pop(context), actions: [
            IconBtn('download', tooltip: 'Download', onTap: _downloading ? null : _download),
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
            Expanded(child: EmptyState(icon: 'file', title: 'Binary file', body: '${formatBytes(f.size)} — can\'t display as text.'))
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
              child: Text('${f.content.split('\n').length} lines · ${formatBytes(f.size)}${f.truncated ? ' · truncated' : ''}',
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
