import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// snippet — Wacht design system (dark), one electric-blue accent.
/// Resolved dark-theme tokens from the design handoff.
// shadcn dark (zinc + indigo). OKLCH tokens converted to sRGB.
class AppColors {
  static const bg = Color(0xFF09090B); // --background
  static const surface1 = Color(0xFF18181B); // --card / --popover / --sidebar
  static const surface2 = Color(0xFF27272A); // --secondary / --muted (inputs, chips)
  static const surface3 = Color(0xFF37373B); // pressed / hover raise

  static const fg1 = Color(0xFFFAFAFA); // --foreground
  static const fg2 = Color(0xFFCACAD1); // secondary text, icons
  static const fg3 = Color(0xFF9F9FA9); // --muted-foreground
  static const fg4 = Color(0xFF797981); // faint icons, disabled

  static const border = Color(0x1AFFFFFF); // --border (white 10%)
  static const border2 = Color(0x26FFFFFF); // --input (white 15%)

  // Indigo accent (bright for a dark UI): fills carry dark text.
  static const accent = Color(0xFF8D98FF);
  static const accentHover = Color(0xFFA6ADFF);
  static const accentFg = Color(0xFF0C0A1F);
  static const accentBg = Color(0x288D98FF); // ~16%
  static const accentLine = Color(0x668D98FF); // 40%
  static const accentRing = Color(0x4D8D98FF); // 30%

  // Status (on-theme: indigo, no green); red for errors.
  static const ok = Color(0xFF8D98FF);
  static const okBg = Color(0x288D98FF);
  static const run = Color(0xFFA6ADFF);
  static const runBg = Color(0x26A6ADFF);
  static const danger = Color(0xFFFF6467); // --destructive
  static const dangerBg = Color(0x26FF6467);

  // diff line tints — additions indigo (no green), deletions red.
  static const diffAddBg = Color(0x208D98FF);
  static const diffDelBg = Color(0x20FF6467);
  static const diffAddFg = Color(0xFF8D98FF);
  static const diffDelFg = Color(0xFFFF9492);
  static const diffGutter = Color(0xFF52525B);
}

// --radius 0.45rem ≈ 7px.
class R {
  static const card = 8.0;
  static const md = 7.0; // buttons, inputs, icon buttons
  static const sm = 5.0; // menu items, list rows
  static const xs = 4.0; // inner chips
  static const sheetTop = 14.0;
}

/// Type helpers — Geist (sans) + Geist Mono, per the handoff recipes.
// Typographic choice: never go heavier than regular (400). Weight passed by call
// sites is capped here so the whole app stays light.
FontWeight _cap(FontWeight w) => w.value > 400 ? FontWeight.w400 : w;

TextStyle sans(double size,
        {FontWeight weight = FontWeight.w400,
        double? height,
        double? spacing,
        Color color = AppColors.fg1}) =>
    GoogleFonts.geist(
      fontSize: size,
      fontWeight: _cap(weight),
      height: height,
      letterSpacing: spacing,
      color: color,
    );

// Code / mono font — JetBrains Mono (a dedicated coding typeface).
TextStyle mono(double size,
        {FontWeight weight = FontWeight.w400,
        double? height,
        Color color = AppColors.fg1}) =>
    GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: _cap(weight),
      height: height,
      color: color,
    );

/// The code font family name (for widgets that need a raw family, e.g. re_editor).
String get monoFamily => GoogleFonts.jetBrainsMono().fontFamily ?? 'monospace';

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.bg,
      primary: AppColors.accent,
      error: AppColors.danger,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    dividerColor: AppColors.border,
    splashColor: AppColors.surface3.withValues(alpha: 0.4),
    highlightColor: AppColors.surface3.withValues(alpha: 0.3),
    textTheme: _allRegular(GoogleFonts.geistTextTheme(base.textTheme)
        .apply(bodyColor: AppColors.fg1, displayColor: AppColors.fg1)),
    // Subtle dividers everywhere (incl. PopupMenuDivider) — no bright lines.
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1, space: 12),
  );
}

/// Force every text style to regular weight (no >400 anywhere).
TextTheme _allRegular(TextTheme t) {
  TextStyle? r(TextStyle? s) => s?.copyWith(fontWeight: FontWeight.w400);
  return t.copyWith(
    displayLarge: r(t.displayLarge), displayMedium: r(t.displayMedium), displaySmall: r(t.displaySmall),
    headlineLarge: r(t.headlineLarge), headlineMedium: r(t.headlineMedium), headlineSmall: r(t.headlineSmall),
    titleLarge: r(t.titleLarge), titleMedium: r(t.titleMedium), titleSmall: r(t.titleSmall),
    bodyLarge: r(t.bodyLarge), bodyMedium: r(t.bodyMedium), bodySmall: r(t.bodySmall),
    labelLarge: r(t.labelLarge), labelMedium: r(t.labelMedium), labelSmall: r(t.labelSmall),
  );
}

/// Map the handoff's Lucide icon names to the Lucide icon set (clean line icons).
IconData iconFor(String name) {
  switch (name) {
    case 'chevron-left':
      return LucideIcons.chevronLeft;
    case 'chevron-right':
      return LucideIcons.chevronRight;
    case 'chevron-down':
      return LucideIcons.chevronDown;
    case 'chevron-up':
      return LucideIcons.chevronUp;
    case 'arrow-right':
      return LucideIcons.arrowRight;
    case 'plus':
      return LucideIcons.plus;
    case 'x':
      return LucideIcons.x;
    case 'more-vertical':
      return LucideIcons.ellipsisVertical;
    case 'search':
      return LucideIcons.search;
    case 'settings':
      return LucideIcons.settings;
    case 'sliders':
      return LucideIcons.slidersHorizontal;
    case 'wifi-off':
      return LucideIcons.wifiOff;
    case 'refresh':
      return LucideIcons.refreshCw;
    case 'alert-triangle':
      return LucideIcons.triangleAlert;
    case 'check':
      return LucideIcons.check;
    case 'check-check':
      return LucideIcons.checkCheck;
    case 'stop':
      return LucideIcons.square;
    case 'send':
      return LucideIcons.arrowUp;
    case 'shield':
      return LucideIcons.shield;
    case 'folder':
      return LucideIcons.folder;
    case 'folder-open':
      return LucideIcons.folderOpen;
    case 'file':
      return LucideIcons.file;
    case 'git-branch':
      return LucideIcons.gitBranch;
    case 'terminal':
      return LucideIcons.terminal;
    case 'grip':
      return LucideIcons.gripVertical;
    case 'edit':
      return LucideIcons.squarePen;
    case 'trash':
      return LucideIcons.trash2;
    case 'key':
      return LucideIcons.key;
    case 'cpu':
      return LucideIcons.cpu;
    case 'layers':
      return LucideIcons.layers;
    case 'activity':
      return LucideIcons.activity;
    case 'image':
      return LucideIcons.image;
    case 'scan':
      return LucideIcons.scanLine;
    case 'camera':
      return LucideIcons.camera;
    case 'camera-off':
      return LucideIcons.cameraOff;
    case 'clipboard':
      return LucideIcons.clipboard;
    case 'history':
      return LucideIcons.history;
    case 'zap':
      return LucideIcons.zap;
    case 'minimize':
      return LucideIcons.minimize;
    case 'rotate':
      return LucideIcons.rotateCcw;
    case 'globe':
      return LucideIcons.globe;
    case 'map':
      return LucideIcons.map;
    case 'list':
      return LucideIcons.list;
    case 'file-plus':
      return LucideIcons.filePlus;
    case 'corner-down-right':
      return LucideIcons.cornerDownRight;
    case 'home':
      return LucideIcons.house;
    case 'clock':
      return LucideIcons.clock;
    default:
      return LucideIcons.circle;
  }
}
