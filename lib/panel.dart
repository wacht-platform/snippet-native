import 'package:flutter/material.dart';

import 'platform.dart';
import 'theme.dart';

enum PanelStyle { drawer, dialog }

/// Present [builder]'s screen as a desktop overlay when the WINDOW is wide
/// (a right-side drawer, or a centered floating dialog), else fall back to a
/// full-screen push (phone). The hosted screen runs inside a nested Navigator
/// so its own sub-pushes (e.g. Git→diff, Files→viewer→editor) stay within the
/// overlay; [builder] is handed a `close` callback to dismiss the whole overlay
/// from the screen's root (wire it to the screen's onClose/back).
Future<T?> presentScreen<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, VoidCallback close) builder,
  PanelStyle style = PanelStyle.drawer,
  bool dismissible = true,
}) {
  // Use the real window width (not a pane-scoped MediaQuery override).
  final view = View.of(context);
  final windowWidth = view.physicalSize.width / view.devicePixelRatio;
  if (windowWidth < kDesktopBreakpoint) {
    return Navigator.of(context).push<T>(MaterialPageRoute(
      builder: (ctx) => builder(ctx, () => Navigator.of(ctx).pop()),
    ));
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'panel',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) {
      void close() => Navigator.of(ctx).pop();
      final content = ClipRRect(
        borderRadius: BorderRadius.circular(style == PanelStyle.dialog ? R.card : 0),
        child: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute(builder: (c) => builder(c, close)),
        ),
      );
      if (style == PanelStyle.dialog) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 860),
              child: _frame(content, rounded: true),
            ),
          ),
        );
      }
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 520,
          height: double.infinity,
          child: _frame(content, rounded: false),
        ),
      );
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

Widget _frame(Widget child, {required bool rounded}) => Material(
      color: AppColors.bg,
      borderRadius: rounded ? BorderRadius.circular(R.card) : null,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: rounded ? BorderRadius.circular(R.card) : null,
          border: rounded
              ? Border.all(color: AppColors.border2)
              : const Border(left: BorderSide(color: AppColors.border2)),
        ),
        child: child,
      ),
    );
