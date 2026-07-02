import 'package:flutter/material.dart';

import 'platform.dart';
import 'theme.dart';

enum PanelStyle { drawer, dialog }

/// Present [builder]'s screen as an overlay whose layout adapts to the window:
/// full-screen when narrow (phone / shrunk window), a right-side drawer or a
/// centered dialog when wide. Because the layout is chosen inside a LayoutBuilder,
/// it re-lays out live when the window crosses the breakpoint while open. Insets
/// below the macOS window controls. [builder] gets a `close` callback to dismiss.
Future<T?> presentScreen<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, VoidCallback close) builder,
  PanelStyle style = PanelStyle.drawer,
  bool dismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'panel',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) {
      void close() => Navigator.of(ctx).pop();
      // Host the screen directly; sub-pushes (file viewer, diff) go to the root
      // navigator over the panel, which is fine.
      final content = builder(ctx, close);
      return LayoutBuilder(builder: (lctx, c) {
        final wide = c.maxWidth >= kDesktopBreakpoint;
        final top = kMacOS ? kMacTitlebar : 0.0;
        if (!wide) {
          // Full-screen (re-lays out to drawer/dialog if the window grows).
          return Padding(padding: EdgeInsets.only(top: top), child: _frame(content, rounded: false, edge: false));
        }
        if (style == PanelStyle.dialog) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 860), child: _frame(content, rounded: true)),
              ),
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: c.maxWidth < 500 ? c.maxWidth : 460.0, height: double.infinity, child: _frame(content, rounded: false, edge: true)),
          ),
        );
      });
    },
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      if (style == PanelStyle.dialog) {
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(curved), child: child),
        );
      }
      return SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
        child: child,
      );
    },
  );
}

/// Present a SELF-CONTAINED screen (no internal sub-pushes) as a centered modal
/// that returns a value. The screen's own `Navigator.pop(context, value)` closes
/// the modal and yields that value (e.g. AddInstanceScreen returning an Instance).
/// Falls back to a full-screen push on phones.
Future<T?> showModal<T>(
  BuildContext context,
  Widget child, {
  double width = 560,
  double height = 540,
}) {
  final view = View.of(context);
  final windowWidth = view.physicalSize.width / view.devicePixelRatio;
  if (windowWidth < kDesktopBreakpoint) {
    return Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => child));
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'modal',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, _, __) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: height),
          child: _frame(child, rounded: true),
        ),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(curved), child: child),
      );
    },
  );
}

// Wide presentations (right drawer / centered dialog) sit on surface1 like
// every other popover, with the hosted Scaffolds re-based onto the same
// surface (single background, no darker strip). Narrow/full-screen keeps the
// plain shell background so phones look exactly as before.
Widget _frame(Widget child, {required bool rounded, bool edge = true}) {
  final panel = rounded || edge;
  final color = panel ? AppColors.surface1 : AppColors.bg;
  return Material(
    color: color,
    borderRadius: rounded ? BorderRadius.circular(R.card) : null,
    clipBehavior: Clip.antiAlias,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: rounded ? BorderRadius.circular(R.card) : null,
        border: rounded
            ? Border.all(color: AppColors.border2)
            : (edge ? const Border(left: BorderSide(color: AppColors.border)) : null),
      ),
      child: !panel
          ? child
          : Builder(
              builder: (ctx) => Theme(
                data: Theme.of(ctx).copyWith(scaffoldBackgroundColor: color),
                child: child,
              ),
            ),
    ),
  );
}
