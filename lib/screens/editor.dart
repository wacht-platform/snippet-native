import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../api.dart';
import '../highlight.dart';
import '../theme.dart';
import '../widgets.dart';

/// Editable code view for one file. Loads via /fs/file, edits with re_editor
/// (syntax highlighting + line numbers), saves via /fs/write with optimistic
/// concurrency — if the file changed on disk since open, the user chooses to
/// overwrite or reload. Binary/oversized files are refused (read-only viewer).
class EditorScreen extends StatefulWidget {
  final DaemonClient client;
  final String path;
  final String name;
  final VoidCallback? onClose; // dismiss when hosted in a desktop panel
  const EditorScreen({super.key, required this.client, required this.path, required this.name, this.onClose});
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final CodeLineEditingController _controller = CodeLineEditingController();
  String _hash = '';
  String _initial = '';
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  // Whether the file arrived with CRLF endings (restored on save).
  bool _crlf = false;

  String _normalized(String s) => s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  String _forSave() {
    final text = _normalized(_controller.text);
    return _crlf ? text.replaceAll('\n', '\r\n') : text;
  }

  void _onChanged() {
    final d = _normalized(_controller.text) != _initial;
    if (d != _dirty && mounted) setState(() => _dirty = d);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final f = await widget.client.readFile(widget.path);
      if (!mounted) return;
      if (!f.editable) {
        setState(() {
          _error = f.binary ? 'Binary file — not editable.' : 'File is too large to edit safely.';
          _loading = false;
        });
        return;
      }
      // The editor normalizes to LF internally: remember the file's dominant
      // line ending so the dirty check compares like-for-like and save restores
      // the original style instead of rewriting every line ending.
      _crlf = f.content.contains('\r\n');
      _initial = _normalized(f.content);
      _hash = f.hash;
      _controller.text = f.content;
      setState(() {
        _loading = false;
        _dirty = false;
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

  Future<void> _save({bool force = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final r = await widget.client.writeFile(widget.path, _forSave(), prevHash: force ? null : _hash);
      if (!mounted) return;
      if (r['ok'] == true) {
        _initial = _normalized(_controller.text);
        _hash = r['hash'] as String? ?? _hash;
        setState(() {
          _dirty = false;
          _saving = false;
        });
        toast(context, 'Saved');
        return;
      }
      setState(() => _saving = false);
      if (r['conflict'] == true) {
        await _conflictSheet();
      } else {
        toast(context, (r['error'] as String?) ?? 'Save failed', danger: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        toast(context, '$e', danger: true);
      }
    }
  }

  Future<void> _conflictSheet() async {
    final choice = await showAppSheet<String>(context, title: 'File changed on disk', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('This file was modified on the server since you opened it (likely by the agent). Keep your version, or reload theirs and lose your edits?',
            style: sans(13, height: 1.45, color: AppColors.fg2)),
        const SizedBox(height: 16),
        Btn('Overwrite with mine', icon: 'check', onTap: () => Navigator.pop(context, 'overwrite')),
        const SizedBox(height: 8),
        Btn('Reload theirs', variant: BtnVariant.secondary, icon: 'refresh', onTap: () => Navigator.pop(context, 'reload')),
        const SizedBox(height: 8),
        Btn('Cancel', variant: BtnVariant.ghost, onTap: () => Navigator.pop(context)),
      ],
    ));
    if (choice == 'overwrite') {
      await _save(force: true);
    } else if (choice == 'reload') {
      await _load();
    }
  }

  void _exit() => (widget.onClose ?? () => Navigator.pop(context))();

  Future<void> _maybePop() async {
    if (!_dirty) {
      _exit();
      return;
    }
    final discard = await showAppSheet<bool>(context, title: 'Discard changes?', child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('You have unsaved edits to this file.', style: sans(13, color: AppColors.fg2)),
        const SizedBox(height: 16),
        Btn('Discard', variant: BtnVariant.danger, onTap: () => Navigator.pop(context, true)),
        const SizedBox(height: 8),
        Btn('Keep editing', variant: BtnVariant.secondary, onTap: () => Navigator.pop(context, false)),
      ],
    ));
    if (discard == true && mounted) _exit();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _maybePop();
      },
      child: Scaffold(
        backgroundColor: readingBg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            SnAppBar(
              title: '${widget.name}${_dirty ? ' •' : ''}',
              subtitle: widget.path,
              onBack: _maybePop,
              actions: [
                if (!_loading && _error == null)
                  IconBtn('check', tooltip: 'Save', active: _dirty, onTap: (_saving || !_dirty) ? null : () => _save()),
              ],
            ),
            if (_saving)
              const LinearProgressIndicator(minHeight: 2, backgroundColor: AppColors.surface2, color: AppColors.accent),
            if (_loading)
              const Expanded(child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg3))))
            else if (_error != null)
              Expanded(child: EmptyState(icon: 'file', title: "Can't edit", body: _error!))
            else
              Expanded(
                child: CodeEditor(
                  controller: _controller,
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
          ]),
        ),
      ),
    );
  }
}
