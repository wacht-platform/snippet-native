import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'platform.dart';

/// snippet — "Terminal Ink" (design direction #3): near-black, mono-forward,
/// chrome kept almost invisible; color carries STATE (amber = active/attention,
/// green = success, red = failure), never decoration.
class AppColors {
  static const bg = Color(0xFF060707); // shell / sidebar
  static const canvas = Color(0xFF0B0D0D); // desktop reading area (a hair up)
  static const surface1 = Color(0xFF0D0F0F); // cards / popovers / sheets
  static const surface2 = Color(0xFF151818); // inputs, chips
  static const surface3 = Color(0xFF1D2120); // pressed / hover raise

  static const fg1 = Color(0xFFE8ECEA); // primary text
  static const fg2 = Color(0xFFAAB2AE); // secondary text, icons
  static const fg3 = Color(0xFF6C7370); // muted
  static const fg4 = Color(0xFF565C59); // faint icons, disabled

  static const border = Color(0x17FFFFFF); // hairline (white ~9%)
  static const border2 = Color(0x24FFFFFF); // inputs (white ~14%)

  // Amber accent — the "live" color; fills carry near-black text.
  static const accent = Color(0xFFE0A458);
  static const accentHover = Color(0xFFEBB470);
  static const accentFg = Color(0xFF160E02);
  static const accentBg = Color(0x26E0A458);
  static const accentLine = Color(0x66E0A458);
  static const accentRing = Color(0x4DE0A458);

  // Status: green = done/ok, amber = running/live, red = failed.
  static const ok = Color(0xFF7BC49A);
  static const okBg = Color(0x267BC49A);
  static const run = Color(0xFFE0A458);
  static const runBg = Color(0x26E0A458);
  static const danger = Color(0xFFE86A6A);
  static const dangerBg = Color(0x26E86A6A);

  // diff line tints — real green/red, terminal-style.
  static const diffAddBg = Color(0x1F7BC49A);
  static const diffDelBg = Color(0x1FE86A6A);
  static const diffAddFg = Color(0xFF9AD4B4);
  static const diffDelFg = Color(0xFFF0A0A0);
  static const diffGutter = Color(0xFF565C59);
}

/// Reading/content surfaces (chat, editor, file viewer, diff). Phones use ONE
/// background everywhere (the darker `bg` — no sidebar/canvas split on a small
/// screen); desktop keeps the lighter canvas against the darker sidebar.
Color get readingBg => kMobile ? AppColors.bg : AppColors.canvas;

// Terminal Ink, softened: crisp but friendly corners.
class R {
  static const card = 14.0;
  static const md = 10.0; // buttons, inputs, icon buttons
  static const sm = 8.0; // menu items, list rows
  static const xs = 6.0; // inner chips
  static const sheetTop = 18.0;
}

/// Type helpers — Terminal Ink: IBM Plex Sans for prose, Source Code Pro for
/// everything technical. Weights are allowed up to semibold for hierarchy, but
/// capped there so nothing shouts.
FontWeight _cap(FontWeight w) => w.value > 600 ? FontWeight.w600 : w;

TextStyle sans(double size,
        {FontWeight weight = FontWeight.w400,
        double? height,
        double? spacing,
        Color color = AppColors.fg1}) =>
    GoogleFonts.ibmPlexSans(
      fontSize: size,
      fontWeight: _cap(weight),
      height: height,
      letterSpacing: spacing,
      color: color,
    );

/// Large display titles (page headers) — same face, a notch heavier + tighter.
TextStyle display(double size, {Color color = AppColors.fg1, double? height}) =>
    GoogleFonts.ibmPlexSans(
      fontSize: size,
      fontWeight: FontWeight.w600,
      height: height,
      letterSpacing: -0.3,
      color: color,
    );

// Code / mono font — Source Code Pro.
TextStyle mono(double size,
        {FontWeight weight = FontWeight.w400,
        double? height,
        Color color = AppColors.fg1}) =>
    GoogleFonts.sourceCodePro(
      fontSize: size,
      fontWeight: _cap(weight),
      height: height,
      color: color,
    );

/// The code font family name (for widgets that need a raw family, e.g. re_editor).
String get monoFamily => GoogleFonts.sourceCodePro().fontFamily ?? 'monospace';

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
    // Selection must be VISIBLE on near-black: a solid amber wash + amber
    // handles (the M3 default was too faint to see what you'd grabbed).
    textSelectionTheme: const TextSelectionThemeData(
      selectionColor: Color(0x59E0A458), // ~35% amber
      cursorColor: AppColors.accent,
      selectionHandleColor: AppColors.accent,
    ),
    splashColor: AppColors.surface3.withValues(alpha: 0.4),
    highlightColor: AppColors.surface3.withValues(alpha: 0.3),
    hoverColor: AppColors.surface3.withValues(alpha: 0.35), // desktop hover raise on every InkWell
    // Popovers/menus: surface1 card look everywhere (never default Material).
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface1,
      elevation: 8,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md), side: const BorderSide(color: AppColors.border2)),
    ),
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

/// Map the app's icon names to Iconsax (linear) — outlined, borderless variants.
IconData iconFor(String name) {
  switch (name) {
    // Directional chevrons: Material's bare glyphs (Iconsax's are circle/box-enclosed).
    case 'chevron-left':
      return Icons.chevron_left_rounded;
    case 'chevron-right':
      return Icons.chevron_right_rounded;
    case 'chevron-down':
      return Icons.expand_more_rounded;
    case 'chevron-up':
      return Icons.expand_less_rounded;
    case 'arrow-right':
      return Icons.arrow_forward_rounded;
    case 'plus':
      return IconsaxPlusLinear.add;
    case 'x':
      return Icons.close_rounded;
    case 'more-vertical':
      return IconsaxPlusLinear.more;
    case 'search':
      return IconsaxPlusLinear.search_normal_1;
    case 'settings':
      return IconsaxPlusLinear.setting_2;
    case 'sliders':
      return IconsaxPlusLinear.setting_4;
    case 'wifi-off':
      return IconsaxPlusLinear.wifi;
    case 'refresh':
      return IconsaxPlusLinear.refresh_2;
    case 'alert-triangle':
      return IconsaxPlusLinear.warning_2;
    case 'check':
      return Icons.check_rounded;
    case 'check-check':
      return Icons.done_all_rounded;
    case 'stop':
      return IconsaxPlusLinear.stop;
    case 'send':
      return IconsaxPlusLinear.arrow_up_3;
    case 'shield':
      return IconsaxPlusLinear.shield_tick;
    case 'folder':
      return IconsaxPlusLinear.folder_2;
    case 'folder-open':
      return IconsaxPlusLinear.folder_open;
    case 'folder-plus':
      return IconsaxPlusLinear.folder_add;
    case 'upload':
      return IconsaxPlusLinear.document_upload;
    case 'download':
      return IconsaxPlusLinear.document_download;
    case 'file':
      return IconsaxPlusLinear.document_text;
    case 'git-branch':
      return IconsaxPlusLinear.hierarchy;
    case 'terminal':
      return IconsaxPlusLinear.code;
    case 'grip':
      return IconsaxPlusLinear.menu;
    case 'edit':
      return IconsaxPlusLinear.edit_2;
    case 'trash':
      return IconsaxPlusLinear.trash;
    case 'key':
      return IconsaxPlusLinear.key;
    case 'cpu':
      return IconsaxPlusLinear.cpu;
    case 'layers':
      return IconsaxPlusLinear.layer;
    case 'activity':
      return IconsaxPlusLinear.activity;
    case 'image':
      return IconsaxPlusLinear.gallery;
    case 'scan':
      return IconsaxPlusLinear.scan;
    case 'camera':
      return IconsaxPlusLinear.camera;
    case 'camera-off':
      return IconsaxPlusLinear.camera_slash;
    case 'clipboard':
      return IconsaxPlusLinear.clipboard_text;
    case 'history':
      return IconsaxPlusLinear.timer_1;
    case 'zap':
      return IconsaxPlusLinear.flash_1;
    case 'minimize':
      return IconsaxPlusLinear.minus;
    case 'rotate':
      return IconsaxPlusLinear.rotate_left;
    case 'globe':
      return IconsaxPlusLinear.global;
    case 'map':
      return IconsaxPlusLinear.map;
    case 'list':
      return IconsaxPlusLinear.menu;
    case 'file-plus':
      return IconsaxPlusLinear.document_upload;
    case 'corner-down-right':
      return IconsaxPlusLinear.direct_right;
    case 'home':
      return IconsaxPlusLinear.home_2;
    case 'clock':
      return IconsaxPlusLinear.clock;
    case 'sidebar':
      return IconsaxPlusLinear.menu;
    case 'menu':
      return IconsaxPlusLinear.menu;
    default:
      return IconsaxPlusLinear.element_3;
  }
}
