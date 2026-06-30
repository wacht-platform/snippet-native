import 'package:flutter/foundation.dart';

/// True on phones/tablets (Android/iOS). Desktop (macOS/Linux/Windows) and web
/// are false. Used to guard mobile-only plugins (foreground task, camera
/// permissions) that have no desktop support, and to pick the layout.
bool get kMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Desktop platforms where we watch /events in-process and raise native local
/// notifications (no foreground service — the app stays running). macOS + Linux.
bool get kDesktopNotify =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// True wherever we can deliver session notifications at all.
bool get kCanNotify => kMobile || kDesktopNotify;

/// macOS specifically — the window draws full-size content, so the traffic-light
/// controls overlay the top-left; the shell insets its top to clear them.
bool get kMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Height to reserve at the top for the macOS window controls.
const double kMacTitlebar = 28.0;

/// The desktop layout (sidebar + panes) kicks in at/above this logical width.
const double kDesktopBreakpoint = 900;

/// Below this shell width the persistent sidebar collapses into a drawer (the
/// desktop shell stays native — it never falls back to the phone UI).
const double kShellCompact = 720;
