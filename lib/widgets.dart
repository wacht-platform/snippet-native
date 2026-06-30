import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'platform.dart';
import 'theme.dart';

/// Open a markdown link in the external browser (fire-and-forget).
void openMarkdownLink(String? href) {
  if (href == null || href.isEmpty) return;
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Themed markdown stylesheet for agent messages.
MarkdownStyleSheet markdownStyle(BuildContext context) {
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: sans(13.5, height: 1.5, color: AppColors.fg1),
    pPadding: EdgeInsets.zero,
    a: sans(13.5, height: 1.5, color: AppColors.accent),
    h1: sans(18, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1),
    h1Padding: const EdgeInsets.only(top: 6, bottom: 2),
    h2: sans(16, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1),
    h3: sans(14.5, weight: FontWeight.w600, height: 1.3, color: AppColors.fg1),
    code: mono(12, color: AppColors.fg1).copyWith(backgroundColor: AppColors.surface2),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: AppColors.surface2,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(R.sm),
    ),
    blockquote: sans(13.5, height: 1.5, color: AppColors.fg2),
    blockquoteDecoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(R.xs),
      border: const Border(left: BorderSide(color: AppColors.accentLine, width: 3)),
    ),
    listBullet: sans(13.5, height: 1.5, color: AppColors.fg1),
    tableBody: sans(12.5, color: AppColors.fg1),
    horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
  );
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
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
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
            : [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1)],
      ),
    );
    if (widget.status == 'checking' || widget.status == 'running') {
      return FadeTransition(opacity: Tween(begin: 0.45, end: 1.0).animate(_c), child: dot);
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
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
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
  const AppCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(14)});
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
      BtnVariant.secondary => (AppColors.surface2, AppColors.fg1, AppColors.border),
      BtnVariant.outline => (Colors.transparent, AppColors.fg1, AppColors.border),
      BtnVariant.ghost => (Colors.transparent, AppColors.fg2, null),
      BtnVariant.danger => (AppColors.dangerBg, AppColors.danger, AppColors.danger.withValues(alpha: 0.3)),
    };
    // Compact on desktop (mouse), roomy touch targets on mobile.
    final h = small ? (kMobile ? 34.0 : 28.0) : (kMobile ? 44.0 : 34.0);
    final child = Row(
      mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[AppIcon(icon!, size: small ? 15 : 17, color: fg), const SizedBox(width: 8)],
        Text(label, style: sans(small ? 12.5 : 13.5, weight: FontWeight.w500, color: fg)),
        if (iconRight != null) ...[const SizedBox(width: 8), AppIcon(iconRight!, size: small ? 15 : 17, color: fg)],
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

class IconBtn extends StatelessWidget {
  final String name;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool active;
  final String? tooltip;
  const IconBtn(this.name,
      {super.key, this.onTap, this.size = 38, this.iconSize = 19, this.active = false, this.tooltip});
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
          child: Icon(iconFor(name), size: iconSize, color: active ? AppColors.accent : AppColors.fg2),
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
            Text(label, style: sans(12.5, weight: FontWeight.w500, color: AppColors.fg2)),
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
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, Radius.circular(radius)));
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

/// One chat message — flat (no bubble/box). YOUR messages get a left accent bar
/// + label; the agent's are plain full-width markdown under a dim label. The bar
/// vs no-bar is the primary you/agent distinction.
class Bubble extends StatelessWidget {
  final bool mine;
  final String text;
  const Bubble({super.key, required this.mine, required this.text});
  @override
  Widget build(BuildContext context) {
    if (mine) {
      return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 2, color: AppColors.accentLine),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('YOU', style: sans(10, color: AppColors.fg1, spacing: 0.8)),
              const SizedBox(height: 4),
              SelectableText(text, style: sans(13.5, height: 1.5, color: AppColors.fg2)),
            ]),
          ),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('SNIPPET', style: sans(10, color: AppColors.fg3, spacing: 0.8)),
      const SizedBox(height: 5),
      // SelectionArea so a drag selects across all markdown blocks at once.
      SelectionArea(
        child: MarkdownBody(
          data: text,
          selectable: false,
          styleSheet: markdownStyle(context),
          onTapLink: (txt, href, title) => openMarkdownLink(href),
        ),
      ),
    ]);
  }
}

/// Mono tool-activity line with an optional result. When [detailBuilder] is set,
/// tapping expands the full detail INLINE (not a drawer).
class ToolLine extends StatefulWidget {
  final String tool;
  final String arg;
  final String? out;
  final bool done;
  final String icon;
  final WidgetBuilder? detailBuilder;
  const ToolLine({super.key, required this.tool, this.arg = '', this.out, this.done = true, this.icon = 'terminal', this.detailBuilder});
  @override
  State<ToolLine> createState() => _ToolLineState();
}

class _ToolLineState extends State<ToolLine> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final expandable = widget.detailBuilder != null;
    final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        AppIcon(widget.icon, size: 13, color: AppColors.fg3),
        const SizedBox(width: 7),
        Text(widget.tool, style: mono(12, color: AppColors.fg1)),
        const SizedBox(width: 7),
        Expanded(child: Text(widget.arg, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(12, color: AppColors.fg3))),
        if (expandable)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: AnimatedRotation(
              turns: _expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: const AppIcon('chevron-right', size: 14, color: AppColors.fg4),
            ),
          ),
      ]),
      if (widget.out != null)
        Padding(
          padding: const EdgeInsets.only(left: 20, top: 3),
          child: Row(children: [
            Text('↳ ', style: mono(11.5, color: widget.done ? AppColors.fg2 : AppColors.fg4)),
            Expanded(child: Text(widget.out!, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11.5, color: AppColors.fg3))),
          ]),
        ),
    ]);
    if (!expandable) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: header);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(R.sm),
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(R.sm),
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4), child: header),
        ),
      ),
      if (_expanded)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 4, 6),
          child: widget.detailBuilder!(context),
        ),
    ]);
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
        mainAxisAlignment: error ? MainAxisAlignment.start : MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error) ...[
            const Padding(padding: EdgeInsets.only(top: 1), child: AppIcon('alert-triangle', size: 12, color: AppColors.danger)),
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
  const StatTile({super.key, required this.label, required this.value, this.sub, this.accent = false});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(R.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: sans(10.5, color: AppColors.fg3)),
        const SizedBox(height: 5),
        Text(value, style: mono(16, weight: FontWeight.w500, color: accent ? AppColors.accent : AppColors.fg1)),
        if (sub != null) ...[const SizedBox(height: 4), Text(sub!, style: mono(10, color: AppColors.fg4))],
      ]),
    );
  }
}

class Progress extends StatelessWidget {
  final double pct; // 0..100
  final Color color;
  final double height;
  const Progress({super.key, required this.pct, this.color = AppColors.accent, this.height = 7});
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
      decoration: BoxDecoration(color: AppColors.runBg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const AppIcon('alert-triangle', size: 11, color: AppColors.run),
        const SizedBox(width: 5),
        Text(label, style: sans(10.5, weight: FontWeight.w500, color: AppColors.run)),
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
            style: sans(10.5, weight: FontWeight.w500, spacing: 0.8, color: AppColors.fg4)),
      );
}

class EmptyState extends StatelessWidget {
  final String icon;
  final String title;
  final String? body;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});
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
        Text(title, style: sans(15, weight: FontWeight.w600, color: AppColors.fg1)),
        if (body != null) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(body!, textAlign: TextAlign.center, style: sans(12.5, height: 1.5, color: AppColors.fg3)),
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
  final List<Widget> actions;
  const SnAppBar({super.key, required this.title, this.subtitle, this.onBack, this.actions = const []});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.fromLTRB(6, 0, 8, 0),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(children: [
        if (onBack != null) IconBtn('chevron-left', iconSize: 22, onTap: onBack) else const SizedBox(width: 8),
        const SizedBox(width: 4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(16, weight: FontWeight.w600, spacing: -0.16, color: AppColors.fg1)),
            if (subtitle != null)
              Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11.5, color: AppColors.fg3)),
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
        Text(widget.label!, style: sans(12, weight: FontWeight.w500, color: AppColors.fg2)),
        const SizedBox(height: 7),
      ],
      AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        constraints: BoxConstraints(minHeight: kMobile ? 44 : 34),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(R.md),
          border: Border.all(color: focused ? AppColors.accent : AppColors.border),
          boxShadow: focused
              ? [BoxShadow(color: AppColors.accentRing, blurRadius: 0, spreadRadius: 2)]
              : null,
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (widget.icon != null) ...[AppIcon(widget.icon!, size: 16, color: AppColors.fg3), const SizedBox(width: 8)],
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
              style: widget.mono ? mono(13, color: AppColors.fg1) : sans(13, color: AppColors.fg1),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: EdgeInsets.symmetric(vertical: kMobile ? 12 : 8),
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: widget.mono ? mono(13, color: AppColors.fg4) : sans(13, color: AppColors.fg4),
              ),
            ),
          ),
          if (widget.rightSlot != null) widget.rightSlot!,
        ]),
      ),
      if (widget.helper != null) ...[
        const SizedBox(height: 7),
        Text(widget.helper!, style: sans(11, height: 1.4, color: AppColors.fg3)),
      ],
    ]);
  }
}

/// Bottom sheet matching the handoff (drag handle, title + close, scroll body).
/// A bottom-sheet single-field text prompt (rename, etc.). Returns the trimmed
/// text on save, or null if cancelled.
Future<String?> promptText(BuildContext context,
    {required String title, String initial = '', String? hint, String saveLabel = 'Save'}) {
  final ctrl = TextEditingController(text: initial);
  return showAppSheet<String>(context, title: title, child: Builder(builder: (ctx) {
    void done() => Navigator.pop(ctx, ctrl.text.trim());
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppField(controller: ctrl, hint: hint, autofocus: true, onSubmitted: (_) => done()),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Btn('Cancel', variant: BtnVariant.secondary, onTap: () => Navigator.pop(ctx))),
          const SizedBox(width: 10),
          Expanded(child: Btn(saveLabel, onTap: done)),
        ]),
      ]),
    );
  }));
}

Future<T?> showAppSheet<T>(BuildContext context, {required String title, required Widget child}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => Container(
      decoration: const BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.sheetTop)),
        border: Border(top: BorderSide(color: AppColors.border2)),
      ),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 9),
        Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: AppColors.border2, borderRadius: BorderRadius.circular(99)))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
          child: Row(children: [
            Expanded(child: Text(title, style: sans(16, weight: FontWeight.w600, color: AppColors.fg1))),
            IconBtn('x', size: 32, iconSize: 18, onTap: () => Navigator.pop(context)),
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
  const AppToggle({super.key, required this.on, required this.onChanged, required this.label, this.sub});
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: sans(13, weight: FontWeight.w500, color: AppColors.fg1)),
              if (sub != null) ...[const SizedBox(height: 3), Text(sub!, style: sans(11, color: AppColors.fg3))],
            ]),
          ),
          const SizedBox(width: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 24,
            decoration: BoxDecoration(color: on ? AppColors.accent : AppColors.surface3, borderRadius: BorderRadius.circular(99)),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.all(3),
                width: 18,
                height: 18,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
