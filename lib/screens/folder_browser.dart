import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

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
              SnAppBar(title: 'Open folder', onBack: () => Navigator.pop(context)),
              if (listing != null)
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
                                _FolderRow(icon: 'folder-open', name: '..', muted: true, onTap: () => _go(listing.parent)),
                              ...listing.entries.map((e) => _FolderRow(
                                    icon: e.isDir ? 'folder' : 'file',
                                    name: e.name,
                                    git: e.git,
                                    disabled: !e.isDir,
                                    chevron: e.isDir,
                                    onTap: e.isDir ? () => _go(e.path) : null,
                                  )),
                            ],
                          ),
              ),
              if (listing != null)
                Container(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const AppIcon('folder-open', size: 14, color: AppColors.accent),
                      const SizedBox(width: 7),
                      Expanded(child: Text(listing.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11.5, color: AppColors.fg3))),
                    ]),
                    const SizedBox(height: 8),
                    Btn(_opening ? 'Opening…' : 'Open this folder', iconRight: 'arrow-right', full: true, disabled: _opening, onTap: () => _open(listing.path)),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final String icon, name;
  final bool git, disabled, muted, chevron;
  final VoidCallback? onTap;
  const _FolderRow({required this.icon, required this.name, this.git = false, this.disabled = false, this.muted = false, this.chevron = false, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(R.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(R.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              AppIcon(icon, size: 18, color: icon == 'file' ? AppColors.fg4 : AppColors.accent),
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
      ),
    );
  }
}
