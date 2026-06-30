import 'package:flutter/material.dart';

import 'desktop_shell.dart';

/// One adaptive shell everywhere. The shell itself responds to width — two-pane
/// when wide, a collapsed sidebar drawer when narrow (phones and shrunk desktop
/// windows alike), so mobile and desktop share the same UI.
class AdaptiveHome extends StatelessWidget {
  const AdaptiveHome({super.key});
  @override
  Widget build(BuildContext context) => const DesktopShell();
}
