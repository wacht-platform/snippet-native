import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// snippet — Wacht design system (dark), one electric-blue accent.
/// Resolved dark-theme tokens from the design handoff.
// Slate — cool blue-grey dark with a teal accent.
class AppColors {
  static const bg = Color(0xFF0D1117); // app background
  static const surface1 = Color(0xFF161B22); // cards, sheets, agent bubbles
  static const surface2 = Color(0xFF1C2330); // inputs, chips, status strip
  static const surface3 = Color(0xFF293040); // pressed / hover raise

  static const fg1 = Color(0xFFE6EDF3); // primary text
  static const fg2 = Color(0xFFADBAC7); // secondary text, icons
  static const fg3 = Color(0xFF768390); // muted / metadata / paths
  static const fg4 = Color(0xFF545D68); // faint icons, disabled

  static const border = Color(0x14FFFFFF); // hairline ~8%
  static const border2 = Color(0x24FFFFFF); // hover/emphasis ~14%

  static const accent = Color(0xFF2DD4BF); // teal
  static const accentHover = Color(0xFF5EEAD4);
  static const accentFg = Color(0xFF062521); // dark text on teal
  static const accentBg = Color(0x242DD4BF); // ~14%
  static const accentLine = Color(0x662DD4BF); // 40%
  static const accentRing = Color(0x4D2DD4BF); // ~30%

  static const ok = Color(0xFF3FB950);
  static const okBg = Color(0x263FB950);
  static const run = Color(0xFFD29922);
  static const runBg = Color(0x26D29922);
  static const danger = Color(0xFFF85149);
  static const dangerBg = Color(0x26F85149);

  // diff line tints (subtler than the *Bg chips)
  static const diffAddBg = Color(0x203FB950);
  static const diffDelBg = Color(0x20F85149);
  static const diffAddFg = Color(0xFF7EE787);
  static const diffDelFg = Color(0xFFFFA198);
  static const diffGutter = Color(0xFF484F58);
}

// Sharp / minimal — small radii throughout.
class R {
  static const card = 6.0;
  static const md = 6.0; // buttons, inputs, icon buttons
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

TextStyle mono(double size,
        {FontWeight weight = FontWeight.w400,
        double? height,
        Color color = AppColors.fg1}) =>
    GoogleFonts.geistMono(
      fontSize: size,
      fontWeight: _cap(weight),
      height: height,
      color: color,
    );

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

/// Map the handoff's Lucide icon names to Material (outlined where it reads as a
/// line icon). Keeps a single naming surface across the app.
IconData iconFor(String name) {
  switch (name) {
    case 'chevron-left':
      return Icons.chevron_left;
    case 'chevron-right':
      return Icons.chevron_right;
    case 'chevron-down':
      return Icons.expand_more;
    case 'chevron-up':
      return Icons.expand_less;
    case 'arrow-right':
      return Icons.arrow_forward;
    case 'plus':
      return Icons.add;
    case 'x':
      return Icons.close;
    case 'more-vertical':
      return Icons.more_vert;
    case 'search':
      return Icons.search;
    case 'settings':
      return Icons.settings_outlined;
    case 'sliders':
      return Icons.tune;
    case 'wifi-off':
      return Icons.wifi_off_rounded;
    case 'refresh':
      return Icons.refresh;
    case 'alert-triangle':
      return Icons.warning_amber_rounded;
    case 'check':
      return Icons.check;
    case 'check-check':
      return Icons.done_all;
    case 'stop':
      return Icons.stop_rounded;
    case 'send':
      return Icons.arrow_upward_rounded;
    case 'shield':
      return Icons.shield_outlined;
    case 'folder':
      return Icons.folder_outlined;
    case 'folder-open':
      return Icons.folder_open_outlined;
    case 'file':
      return Icons.insert_drive_file_outlined;
    case 'git-branch':
      return Icons.account_tree_outlined;
    case 'terminal':
      return Icons.terminal_rounded;
    case 'grip':
      return Icons.drag_handle;
    case 'edit':
      return Icons.edit_outlined;
    case 'trash':
      return Icons.delete_outline;
    case 'key':
      return Icons.vpn_key_outlined;
    case 'cpu':
      return Icons.memory_outlined;
    case 'layers':
      return Icons.layers_outlined;
    case 'activity':
      return Icons.show_chart;
    case 'image':
      return Icons.image_outlined;
    case 'scan':
      return Icons.qr_code_scanner;
    case 'camera':
      return Icons.photo_camera_outlined;
    case 'camera-off':
      return Icons.no_photography_outlined;
    case 'clipboard':
      return Icons.content_paste;
    case 'history':
      return Icons.history;
    case 'zap':
      return Icons.bolt_outlined;
    case 'minimize':
      return Icons.remove;
    case 'rotate':
      return Icons.restore;
    case 'globe':
      return Icons.public;
    case 'map':
      return Icons.account_tree_outlined;
    case 'list':
      return Icons.format_list_bulleted;
    case 'file-plus':
      return Icons.note_add_outlined;
    case 'corner-down-right':
      return Icons.subdirectory_arrow_right;
    case 'home':
      return Icons.home_outlined;
    case 'clock':
      return Icons.schedule;
    default:
      return Icons.circle_outlined;
  }
}
