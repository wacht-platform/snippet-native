import 'package:google_fonts/google_fonts.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

import 'theme.dart';

/// Shared CodeEditor style — Geist Mono (matches the app's `mono` typography),
/// app colors, and syntax highlighting by file extension. Used by both the
/// editor and the read-only file viewer so they look identical.
CodeEditorStyle codeEditorStyle(String filename) => CodeEditorStyle(
      fontSize: 13,
      fontHeight: 1.5,
      fontFamily: GoogleFonts.geistMono().fontFamily,
      fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
      textColor: AppColors.fg1,
      backgroundColor: AppColors.bg,
      codeTheme: highlightThemeFor(filename),
    );

/// Syntax-highlight theme for a file chosen by its extension, or null when the
/// language is unknown (callers then render plain text). Shared by the editor
/// and the read-only file viewer.
CodeHighlightTheme? highlightThemeFor(String filename) {
  final lower = filename.toLowerCase();
  final ext = lower.contains('.') ? lower.split('.').last : lower;
  final lang = _extToLang[ext];
  final mode = lang == null ? null : builtinAllLanguages[lang];
  if (mode == null) return null;
  return CodeHighlightTheme(
    languages: {lang!: CodeHighlightThemeMode(mode: mode)},
    theme: atomOneDarkTheme,
  );
}

const Map<String, String> _extToLang = {
  'dart': 'dart',
  'js': 'javascript', 'jsx': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
  'ts': 'typescript', 'tsx': 'typescript',
  'py': 'python', 'rs': 'rust', 'go': 'go', 'java': 'java', 'kt': 'kotlin', 'swift': 'swift',
  'c': 'c', 'h': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp', 'hpp': 'cpp',
  'cs': 'csharp', 'rb': 'ruby', 'php': 'php',
  'sh': 'bash', 'bash': 'bash', 'zsh': 'bash',
  'json': 'json', 'yaml': 'yaml', 'yml': 'yaml', 'toml': 'ini', 'ini': 'ini',
  'xml': 'xml', 'html': 'xml', 'htm': 'xml', 'css': 'css', 'scss': 'scss',
  'md': 'markdown', 'markdown': 'markdown', 'sql': 'sql',
};
