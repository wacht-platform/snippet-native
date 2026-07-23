import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'platform.dart';
import 'theme.dart';

OverlayEntry? _activeToast;
Timer? _toastTimer;

/// A slick, theme-styled toast rendered in the ROOT overlay — so it floats above
/// panels/dialogs instead of a SnackBar buried behind a modal backdrop. A new one
/// replaces the previous (no stacking). Use for transient feedback.
void toast(BuildContext context, String message, {bool danger = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _activeToast?.remove();
  _toastTimer?.cancel();
  final entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(ctx).padding.bottom + 28,
      child: IgnorePointer(
          child: Center(child: _ToastCard(message: message, danger: danger))),
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
  _toastTimer = Timer(const Duration(milliseconds: 2600), () {
    if (_activeToast == entry) {
      entry.remove();
      _activeToast = null;
    }
  });
}

/// A toast with tappable action buttons (e.g. Open / Share after a download).
/// Unlike [toast] it isn't IgnorePointer'd, and it lingers longer so the actions
/// are reachable. Tapping an action dismisses it.
typedef ToastAction = ({String label, String icon, VoidCallback onTap});

void actionToast(BuildContext context, String message,
    {required List<ToastAction> actions}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _activeToast?.remove();
  _toastTimer?.cancel();
  late final OverlayEntry entry;
  void dismiss() {
    if (_activeToast == entry) {
      entry.remove();
      _activeToast = null;
      _toastTimer?.cancel();
    }
  }

  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(ctx).padding.bottom + 28,
      child: Center(
        child: _ToastCard(
          message: message,
          danger: false,
          actions: actions
              .map((a) => (
                    label: a.label,
                    icon: a.icon,
                    onTap: () {
                      // Run the action first, then tear the toast down — removing the
                      // overlay entry mid-tap could otherwise swallow the action.
                      a.onTap();
                      dismiss();
                    }
                  ))
              .toList(),
        ),
      ),
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
  _toastTimer = Timer(const Duration(milliseconds: 6000), dismiss);
}

class _ToastCard extends StatefulWidget {
  final String message;
  final bool danger;
  final List<ToastAction> actions;
  const _ToastCard(
      {required this.message, required this.danger, this.actions = const []});
  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220))
    ..forward();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    final accent = widget.danger ? AppColors.danger : AppColors.accent;
    // Material ancestor: without it, text floating in the root Overlay falls back
    // to the debug default style (the yellow underline). It also gives clean ink.
    return Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.18), end: Offset.zero)
              .animate(curve),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(R.card),
              border: Border.all(color: AppColors.border),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 28,
                    offset: Offset(0, 10))
              ],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                    child: AppIcon(widget.danger ? 'alert-triangle' : 'check',
                        size: 14, color: accent)),
              ),
              const SizedBox(width: 11),
              Flexible(
                child: Text(widget.message,
                    style: sans(13, height: 1.3, color: AppColors.fg1)
                        .copyWith(decoration: TextDecoration.none)),
              ),
              for (final a in widget.actions) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: a.onTap,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(R.sm),
                      border: Border.all(color: AppColors.border2),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      AppIcon(a.icon, size: 13, color: AppColors.fg1),
                      const SizedBox(width: 6),
                      Text(a.label,
                          style: sans(12.5,
                                  weight: FontWeight.w600, color: AppColors.fg1)
                              .copyWith(decoration: TextDecoration.none)),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Open a markdown link in the external browser (fire-and-forget).
/// Compact relative time like "now", "5m", "3h", "2d", "4mo" (empty for 0).
String relativeTime(int unixSec) {
  if (unixSec == 0) return '';
  final d = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(unixSec * 1000));
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 30) return '${d.inDays}d';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo';
  return '${(d.inDays / 365).floor()}y';
}

/// Human-readable byte size (B / KB / MB). Accepts an int or anything parseable.
String formatBytes(dynamic n) {
  final b = n is int ? n : int.tryParse(n.toString()) ?? 0;
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Last non-empty path segment (the folder/file name), or [ifEmpty] when there is none.
String lastPathSegment(String path, {String ifEmpty = ''}) {
  final seg = path.split('/').where((p) => p.isNotEmpty).lastOrNull;
  return seg ?? (path.isEmpty ? ifEmpty : path);
}

/// A row of selectable rounded pills. [items] maps each value to its label;
/// [onSelect] null disables the whole row (e.g. a locked field).
class Pills<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T>? onSelect;
  const Pills(
      {super.key, required this.items, required this.selected, this.onSelect});
  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 7, runSpacing: 7, children: [
        for (final (val, label) in items)
          GestureDetector(
            onTap: onSelect == null ? null : () => onSelect!(val),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color:
                    selected == val ? AppColors.accentBg : AppColors.surface2,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                    color: selected == val
                        ? AppColors.accentLine
                        : AppColors.border),
              ),
              child: Text(label,
                  style: sans(12.5,
                      weight: FontWeight.w500,
                      color:
                          selected == val ? AppColors.accent : AppColors.fg2)),
            ),
          ),
      ]);
}

void openMarkdownLink(String? href) {
  if (href == null || href.isEmpty) return;
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Themed markdown stylesheet for agent messages.
MarkdownStyleSheet markdownStyle(BuildContext context) {
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: sans(16, height: 1.5, color: AppColors.fg1),
    pPadding: EdgeInsets.zero,
    a: sans(16, height: 1.5, color: AppColors.accent),
    h1: sans(21, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1),
    h1Padding: const EdgeInsets.only(top: 6, bottom: 2),
    h2: sans(18.5, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1),
    h3: sans(16.5, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1),
    // Inline style fallback; CodeBlockBuilder draws the real pill.
    code: mono(13.5, color: AppColors.accent),
    // PreBlockBuilder owns fenced chrome — keep these empty to avoid a double box.
    codeblockPadding: EdgeInsets.zero,
    codeblockDecoration: const BoxDecoration(),
    blockquote: sans(15.5, height: 1.5, color: AppColors.fg2),
    blockquoteDecoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(R.xs),
      border:
          const Border(left: BorderSide(color: AppColors.accentLine, width: 3)),
    ),
    listBullet: sans(16, height: 1.5, color: AppColors.fg1),
    tableBody: sans(14, color: AppColors.fg1),
    // FlexColumnWidth stretches every markdown table to the full message width.
    // Intrinsic columns keep phone tables content-sized; the markdown package
    // supplies horizontal scrolling when a long URL or code value needs it.
    tableColumnWidth:
        kMobile ? const IntrinsicColumnWidth() : const FlexColumnWidth(),
    horizontalRuleDecoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border))),
  );
}

/// Inline `code` only. Fenced blocks are handled by [PreBlockBuilder] on `pre`
/// so we don't nest a second chrome box or paint the accent pill on whole blocks.
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final raw = element.textContent;
    final isBlock = raw.contains('\n') ||
        (element.attributes['class'] ?? '').startsWith('language-');
    if (isBlock) {
      // Nested under <pre> — PreBlockBuilder owns the chrome; return plain text.
      final code = raw.endsWith('\n') ? raw.substring(0, raw.length - 1) : raw;
      return Text(code, style: mono(13, height: 1.5, color: AppColors.fg1));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.accentBg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(raw, style: mono(13.5, color: AppColors.accent)),
    );
  }
}

/// Fenced ``` blocks — full-width surface, clean border, copy chip. Registered
/// on `pre` so flutter_markdown does not also wrap us in codeblockDecoration.
class PreBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return _MdCodeBlock(code: code);
  }
}

class _MdCodeBlock extends StatefulWidget {
  final String code;
  const _MdCodeBlock({required this.code});
  @override
  State<_MdCodeBlock> createState() => _MdCodeBlockState();
}

class _MdCodeBlockState extends State<_MdCodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surface2,
          border: Border.all(color: AppColors.border2),
          borderRadius: BorderRadius.circular(R.sm),
        ),
        child: Stack(
          children: [
            // Keep code-block scroll notifications from reaching the shell's
            // PageView/drawer gesture handler.
            NotificationListener<ScrollNotification>(
              onNotification: (_) => true,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(14, 14, 44, 14),
                child: Text(
                  widget.code,
                  style: mono(13, height: 1.55, color: AppColors.fg1),
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(R.xs),
                  onTap: _copy,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.surface3,
                      borderRadius: BorderRadius.circular(R.xs),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: AppIcon(
                      _copied ? 'check' : 'clipboard',
                      size: 13,
                      color: _copied ? AppColors.ok : AppColors.fg3,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Line icon (Material outlined, mapped from the handoff's Lucide names).
class AppIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;
  const AppIcon(this.name, {super.key, this.size = 18, this.color});
  @override
  Widget build(BuildContext context) =>
      Icon(iconFor(name), size: size, color: color ?? AppColors.fg2);
}

/// Glowing status dot.
class StatusDot extends StatefulWidget {
  final String status; // online | running | offline | checking
  final double size;
  const StatusDot({super.key, this.status = 'online', this.size = 9});
  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color get _color => switch (widget.status) {
        'online' => AppColors.ok,
        'running' => AppColors.run,
        'offline' => AppColors.danger,
        _ => AppColors.fg3,
      };

  @override
  Widget build(BuildContext context) {
    final c = _color;
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        boxShadow: widget.status == 'offline'
            ? null
            : [
                BoxShadow(
                    color: c.withValues(alpha: 0.6),
                    blurRadius: 8,
                    spreadRadius: 1)
              ],
      ),
    );
    if (widget.status == 'checking' || widget.status == 'running') {
      return FadeTransition(
          opacity: Tween(begin: 0.45, end: 1.0).animate(_c), child: dot);
    }
    return dot;
  }
}

/// Rounded status pill with a leading dot.
class StatusPill extends StatelessWidget {
  final String status;
  const StatusPill({super.key, required this.status});
  @override
  Widget build(BuildContext context) {
    final (Color c, Color bg, String label, bool live) = switch (status) {
      'running' => (AppColors.run, AppColors.runBg, 'Running', true),
      'online' => (AppColors.ok, AppColors.okBg, 'Online', true),
      'offline' => (AppColors.danger, AppColors.dangerBg, 'Offline', false),
      'error' => (AppColors.danger, AppColors.dangerBg, 'Error', false),
      'checking' => (AppColors.fg3, AppColors.surface2, 'Checking', false),
      _ => (AppColors.fg3, AppColors.surface2, 'Idle', false),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 9, 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: sans(11, weight: FontWeight.w500, color: c)),
      ]),
    );
  }
}

/// Surface-1 card with a hairline border.
class AppCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  const AppCard(
      {super.key,
      required this.child,
      this.onTap,
      this.padding = const EdgeInsets.all(14)});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(R.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.card),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(R.card),
            border: Border.all(color: AppColors.border),
          ),
          child: child,
        ),
      ),
    );
  }
}

enum BtnVariant { primary, secondary, outline, ghost, danger }

class Btn extends StatelessWidget {
  final String label;
  final BtnVariant variant;
  final bool small;
  final bool full;
  final bool disabled;
  final String? icon;
  final String? iconRight;
  final VoidCallback? onTap;
  const Btn(this.label,
      {super.key,
      this.variant = BtnVariant.primary,
      this.small = false,
      this.full = false,
      this.disabled = false,
      this.icon,
      this.iconRight,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, Color? bd) = switch (variant) {
      BtnVariant.primary => (AppColors.accent, AppColors.accentFg, null),
      BtnVariant.secondary => (
          AppColors.surface2,
          AppColors.fg1,
          AppColors.border
        ),
      BtnVariant.outline => (
          Colors.transparent,
          AppColors.fg1,
          AppColors.border
        ),
      BtnVariant.ghost => (Colors.transparent, AppColors.fg2, null),
      BtnVariant.danger => (
          AppColors.dangerBg,
          AppColors.danger,
          AppColors.danger.withValues(alpha: 0.3)
        ),
    };
    // Compact on desktop (mouse), roomy touch targets on mobile.
    final h = small ? (kMobile ? 34.0 : 28.0) : (kMobile ? 44.0 : 34.0);
    final child = Row(
      mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          AppIcon(icon!, size: small ? 15 : 17, color: fg),
          const SizedBox(width: 8)
        ],
        Text(label,
            style:
                sans(small ? 12.5 : 13.5, weight: FontWeight.w500, color: fg)),
        if (iconRight != null) ...[
          const SizedBox(width: 8),
          AppIcon(iconRight!, size: small ? 15 : 17, color: fg)
        ],
      ],
    );
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(R.md),
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(R.md),
          child: Container(
            height: h,
            width: full ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: small ? 12 : 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(R.md),
              border: bd != null ? Border.all(color: bd) : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Accent pill action (Claude-style primary affordance).
class PillBtn extends StatelessWidget {
  final String label;
  final String? icon;
  final VoidCallback? onTap;
  const PillBtn(this.label, {super.key, this.icon, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Material(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(99),
          child: Container(
            height: kMobile ? 48 : 36,
            padding: EdgeInsets.symmetric(horizontal: kMobile ? 20 : 16),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                AppIcon(icon!,
                    size: kMobile ? 18 : 16, color: AppColors.accentFg),
                const SizedBox(width: 8),
              ],
              Text(label,
                  style: sans(kMobile ? 14.5 : 13,
                      weight: FontWeight.w500, color: AppColors.accentFg)),
            ]),
          ),
        ),
      ),
    );
  }
}

class IconBtn extends StatelessWidget {
  final String name;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool active;
  final String? tooltip;
  const IconBtn(this.name,
      {super.key,
      this.onTap,
      this.size = 38,
      this.iconSize = 19,
      this.active = false,
      this.tooltip});
  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: active ? AppColors.accentBg : Colors.transparent,
      borderRadius: BorderRadius.circular(R.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.md),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(iconFor(name),
              size: iconSize, color: active ? AppColors.accent : AppColors.fg2),
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
  }
}

/// Dashed add / empty card.
class AddCard extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const AddCard({super.key, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(R.card),
      child: CustomPaint(
        painter: _DashedBorder(color: AppColors.border2, radius: R.card),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.all(12),
          alignment: Alignment.center,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const AppIcon('plus', size: 15),
            const SizedBox(width: 8),
            Text(label,
                style:
                    sans(12.5, weight: FontWeight.w500, color: AppColors.fg2)),
          ]),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  final Color color;
  final double radius;
  const _DashedBorder({required this.color, required this.radius});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(
          RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    const dash = 5.0, gap = 4.0;
    for (final m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, (d + dash).clamp(0, m.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorder old) => old.color != color;
}

/// Internal attachment and transcription markers are agent-facing metadata, not
/// user-facing chat text.
final RegExp _attachMarkerRe =
    RegExp(r'\[attached (image|file) —[^\]]*\]', multiLine: true);
final RegExp _audioTranscriptRe = RegExp(
  r'(?:\r?\n)*\[Audio transcript for [^\]\r\n]+\]\r?\n[\s\S]*$',
);

/// Strip internal attachment/transcription metadata from displayed text. The
/// original message still contains it when sent to the daemon, so the agent can
/// use the transcript while the user sees only their own message and attachment.
String hideAttachmentMarkers(String raw) => raw
    .replaceAll(_audioTranscriptRe, '')
    .replaceAll(_attachMarkerRe, '')
    .trim();

/// Read-only attachment summary on a sent message — icon + count, no emoji.
/// Images and files each get their own compact pill (matches desktop).
class AttachmentPill extends StatelessWidget {
  final int images, files;
  const AttachmentPill({super.key, required this.images, required this.files});
  @override
  Widget build(BuildContext context) {
    Widget pill(String icon, String label) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(R.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(icon, size: 13, color: AppColors.fg3),
            const SizedBox(width: 6),
            Text(label, style: sans(12.5, color: AppColors.fg2)),
          ]),
        );
    final pills = <Widget>[];
    if (images > 0) {
      pills.add(pill('image', images == 1 ? 'image' : '$images images'));
    }
    if (files > 0) {
      pills.add(pill('file', files == 1 ? 'file' : '$files files'));
    }
    if (pills.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(spacing: 8, runSpacing: 6, children: pills),
    );
  }
}

/// One chat message — flat (no bubble/box). YOUR messages get a left accent bar
/// + label; the agent's are plain full-width markdown under a dim label. The bar
/// vs no-bar is the primary you/agent distinction.
class Bubble extends StatelessWidget {
  final bool mine;
  final String text;
  const Bubble({super.key, required this.mine, required this.text});
  @override
  Widget build(BuildContext context) {
    final matches = _attachMarkerRe.allMatches(text).toList();
    final shown = hideAttachmentMarkers(text);
    final images = matches.where((m) => m.group(1) == 'image').length;
    final files = matches.length - images;
    // Clean, Claude-style: a readable sender header (no accent bar / outline),
    // differentiated by name + colour rather than a border.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        mine ? 'You' : 'Snippet',
        style: sans(13.5,
            weight: FontWeight.w600,
            color: mine ? AppColors.fg2 : AppColors.accent),
      ),
      const SizedBox(height: 6),
      if (mine) ...[
        // Plain Text on purpose: the transcript is wrapped in ONE SelectionArea
        // (session.dart), which gives continuous selection ACROSS paragraphs and
        // messages. Per-widget SelectableText would break that continuity.
        if (shown.isNotEmpty)
          Text(shown, style: sans(16, height: 1.5, color: AppColors.fg1)),
        // A sent attachment stays visible as a pill (below any text it came with).
        if (matches.isNotEmpty) ...[
          if (shown.isNotEmpty) const SizedBox(height: 8),
          AttachmentPill(images: images, files: files),
        ],
      ] else ...[
        // selectable: false on purpose — with `true`, EVERY markdown block is its
        // own SelectableText, so a selection can't cross paragraphs and renders
        // patchily. The transcript-level SelectionArea (session.dart) now owns
        // selection: continuous across blocks AND messages, native handles.
        MarkdownBody(
          data: shown,
          selectable: false,
          styleSheet: markdownStyle(context),
          builders: {'pre': PreBlockBuilder()},
          onTapLink: (txt, href, title) => openMarkdownLink(href),
        ),
        // Copy only on agent messages.
        _CopyButton(text: shown),
      ],
    ]);
  }
}

/// Small "Copy" affordance under a message — copies the text to the clipboard.
class _CopyButton extends StatelessWidget {
  final String text;
  const _CopyButton({required this.text});
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.xs),
          onTap: () {
            Clipboard.setData(ClipboardData(text: text));
            toast(context, 'Copied');
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.copy_rounded, size: 12.5, color: AppColors.fg4),
              const SizedBox(width: 4),
              Text('Copy', style: sans(11, color: AppColors.fg4)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Mono tool-activity line with an optional result. Tappable → detail drawer.
class ToolLine extends StatelessWidget {
  final String tool;
  final String arg;
  final String? out;
  final bool done;
  final String icon;
  final VoidCallback? onTap;
  const ToolLine(
      {super.key,
      required this.tool,
      this.arg = '',
      this.out,
      this.done = true,
      this.icon = 'terminal',
      this.onTap});
  @override
  Widget build(BuildContext context) {
    final inner =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        AppIcon(icon, size: 13, color: AppColors.fg3),
        const SizedBox(width: 7),
        Text(tool, style: mono(12, color: AppColors.fg1)),
        const SizedBox(width: 7),
        Expanded(
            child: Text(arg,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(12, color: AppColors.fg3))),
        if (onTap != null)
          const Padding(
              padding: EdgeInsets.only(left: 4),
              child: AppIcon('chevron-right', size: 14, color: AppColors.fg4)),
      ]),
      if (out != null)
        Padding(
          padding: const EdgeInsets.only(left: 20, top: 3),
          child: Row(children: [
            Text('↳ ',
                style: mono(11.5, color: done ? AppColors.fg2 : AppColors.fg4)),
            Expanded(
                child: Text(out!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(11.5, color: AppColors.fg3))),
          ]),
        ),
    ]);
    if (onTap == null)
      return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2), child: inner);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.sm),
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: inner),
      ),
    );
  }
}

/// Dim note (centered) / error (left-aligned, capped at two lines).
class NoteLine extends StatelessWidget {
  final String text;
  final bool error;
  const NoteLine(this.text, {super.key, this.error = false});
  @override
  Widget build(BuildContext context) {
    final c = error ? AppColors.danger : AppColors.fg3;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
      child: Row(
        mainAxisAlignment:
            error ? MainAxisAlignment.start : MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error) ...[
            const Padding(
                padding: EdgeInsets.only(top: 1),
                child: AppIcon('alert-triangle',
                    size: 12, color: AppColors.danger)),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Text(text,
                textAlign: error ? TextAlign.left : TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: mono(11.5, height: 1.35, color: c)),
          ),
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final bool accent;
  const StatTile(
      {super.key,
      required this.label,
      required this.value,
      this.sub,
      this.accent = false});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(R.md),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: sans(10.5, color: AppColors.fg3)),
            const SizedBox(height: 5),
            Text(value,
                style: mono(16,
                    weight: FontWeight.w500,
                    color: accent ? AppColors.accent : AppColors.fg1)),
            if (sub != null) ...[
              const SizedBox(height: 4),
              Text(sub!, style: mono(10, color: AppColors.fg4))
            ],
          ]),
    );
  }
}

class Progress extends StatelessWidget {
  final double pct; // 0..100
  final Color color;
  final double height;
  const Progress(
      {super.key,
      required this.pct,
      this.color = AppColors.accent,
      this.height = 7});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        value: (pct / 100).clamp(0, 1),
        minHeight: height,
        backgroundColor: AppColors.surface2,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}

class WarnChip extends StatelessWidget {
  final String label;
  const WarnChip({super.key, this.label = 'No key'});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: AppColors.runBg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const AppIcon('alert-triangle', size: 11, color: AppColors.run),
        const SizedBox(width: 5),
        Text(label,
            style: sans(10.5, weight: FontWeight.w500, color: AppColors.run)),
      ]),
    );
  }
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 2),
        child: Text(text.toUpperCase(),
            style: sans(10.5,
                weight: FontWeight.w500, spacing: 0.8, color: AppColors.fg4)),
      );
}

class EmptyState extends StatelessWidget {
  final String icon;
  final String title;
  final String? body;
  final Widget? action;
  const EmptyState(
      {super.key,
      required this.icon,
      required this.title,
      this.body,
      this.action});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: AppIcon(icon, size: 24, color: AppColors.fg3),
        ),
        const SizedBox(height: 12),
        Text(title,
            style: sans(15, weight: FontWeight.w600, color: AppColors.fg1)),
        if (body != null) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(body!,
                textAlign: TextAlign.center,
                style: sans(12.5, height: 1.5, color: AppColors.fg3)),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 16), action!],
      ]),
    );
  }
}

/// Custom app bar matching the handoff (back + title/mono-subtitle + right + ⋯).
class SnAppBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final Widget? leading;
  final List<Widget> actions;
  const SnAppBar(
      {super.key,
      required this.title,
      this.subtitle,
      this.onBack,
      this.leading,
      this.actions = const []});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.fromLTRB(6, 0, 8, 0),
      decoration: BoxDecoration(
        // Follows the ambient shell surface — desktop panels re-theme this to
        // surface1 so the bar never reads as a darker strip (mobile: still bg).
        color: Theme.of(context).scaffoldBackgroundColor,
        border: const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(children: [
        if (leading != null)
          leading!
        else if (onBack != null)
          IconBtn('chevron-left',
              size: kMobile ? 42 : 38,
              iconSize: kMobile ? 27 : 22,
              onTap: onBack)
        else
          const SizedBox(width: 8),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: display(17)),
                if (subtitle != null)
                  Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(11.5, color: AppColors.fg3)),
              ]),
        ),
        ...actions,
      ]),
    );
  }
}

/// Labeled input: focus → accent border + ring.
class AppField extends StatefulWidget {
  final String? label;
  final TextEditingController controller;
  final String? hint;
  final String? helper;
  final bool mono;
  final bool obscure;
  final String? icon;
  final Widget? rightSlot;
  final int minLines;
  final int maxLines;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  const AppField({
    super.key,
    this.label,
    required this.controller,
    this.hint,
    this.helper,
    this.mono = false,
    this.obscure = false,
    this.icon,
    this.rightSlot,
    this.minLines = 1,
    this.maxLines = 1,
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.onSubmitted,
  });
  @override
  State<AppField> createState() => _AppFieldState();
}

class _AppFieldState extends State<AppField> {
  final _focus = FocusNode();
  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.label != null) ...[
        Text(widget.label!,
            style: sans(12, weight: FontWeight.w500, color: AppColors.fg2)),
        const SizedBox(height: 7),
      ],
      AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        constraints: BoxConstraints(minHeight: kMobile ? 44 : 34),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(R.md),
          border:
              Border.all(color: focused ? AppColors.accent : AppColors.border),
          boxShadow: focused
              ? [
                  BoxShadow(
                      color: AppColors.accentRing,
                      blurRadius: 0,
                      spreadRadius: 2)
                ]
              : null,
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (widget.icon != null) ...[
            AppIcon(widget.icon!, size: 16, color: AppColors.fg3),
            const SizedBox(width: 8)
          ],
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              obscureText: widget.obscure,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              autofocus: widget.autofocus,
              keyboardType: widget.keyboardType,
              onSubmitted: widget.onSubmitted,
              cursorColor: AppColors.accent,
              style: widget.mono
                  ? mono(13, color: AppColors.fg1)
                  : sans(13, color: AppColors.fg1),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding:
                    EdgeInsets.symmetric(vertical: kMobile ? 12 : 8),
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: widget.mono
                    ? mono(13, color: AppColors.fg4)
                    : sans(13, color: AppColors.fg4),
              ),
            ),
          ),
          if (widget.rightSlot != null) widget.rightSlot!,
        ]),
      ),
      if (widget.helper != null) ...[
        const SizedBox(height: 7),
        Text(widget.helper!,
            style: sans(11, height: 1.4, color: AppColors.fg3)),
      ],
    ]);
  }
}

/// Bottom sheet matching the handoff (drag handle, title + close, scroll body).
/// A bottom-sheet single-field text prompt (rename, etc.). Returns the trimmed
/// text on save, or null if cancelled.
Future<String?> promptText(BuildContext context,
    {required String title,
    String initial = '',
    String? hint,
    String saveLabel = 'Save'}) {
  final ctrl = TextEditingController(text: initial);
  return showAppSheet<String>(context, title: title,
      child: Builder(builder: (ctx) {
    void done() => Navigator.pop(ctx, ctrl.text.trim());
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppField(
                controller: ctrl,
                hint: hint,
                autofocus: true,
                onSubmitted: (_) => done()),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                  child: Btn('Cancel',
                      variant: BtnVariant.secondary,
                      onTap: () => Navigator.pop(ctx))),
              const SizedBox(width: 10),
              Expanded(child: Btn(saveLabel, onTap: done)),
            ]),
          ]),
    );
  }));
}

Future<T?> showAppSheet<T>(BuildContext context,
    {required String title, required Widget child}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Centered, width-capped on desktop (phones are narrower than this → unchanged).
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => Container(
      decoration: const BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.sheetTop)),
        border: Border(top: BorderSide(color: AppColors.border2)),
      ),
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 9),
        Center(
            child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                    color: AppColors.border2,
                    borderRadius: BorderRadius.circular(99)))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
          child: Row(children: [
            Expanded(
                child: Text(title,
                    style: sans(16,
                        weight: FontWeight.w600, color: AppColors.fg1))),
            IconBtn('x',
                size: 32, iconSize: 18, onTap: () => Navigator.pop(context)),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: child,
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom),
      ]),
    ),
  );
}

class AppToggle extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onChanged;
  final String label;
  final String? sub;
  const AppToggle(
      {super.key,
      required this.on,
      required this.onChanged,
      required this.label,
      this.sub});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!on),
      borderRadius: BorderRadius.circular(R.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(R.md),
        ),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style:
                      sans(13, weight: FontWeight.w500, color: AppColors.fg1)),
              if (sub != null) ...[
                const SizedBox(height: 3),
                Text(sub!, style: sans(11, color: AppColors.fg3))
              ],
            ]),
          ),
          const SizedBox(width: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 24,
            decoration: BoxDecoration(
                color: on ? AppColors.accent : AppColors.surface3,
                borderRadius: BorderRadius.circular(99)),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.all(3),
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
