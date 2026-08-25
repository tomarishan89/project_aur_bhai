import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

/// Available curated base themes.
enum AppThemePalette {
  midnightCyber('Midnight Cyber', 'Sleek futuristic deep dark with neon undertones'),
  warmObsidian('Warm Obsidian', 'Cozy charcoal and warm graphite slate'),
  deepTwilight('Deep Twilight', 'Rich midnight navy and cosmic indigo'),
  matrixMint('Matrix Mint', 'Cybernetic terminal forest and dark emerald'),
  solarisLight('Solaris Light', 'High-clarity crisp daylight canvas');

  final String label;
  final String description;
  const AppThemePalette(this.label, this.description);
}

/// Available accent glow highlights.
enum AppAccentGlow {
  cyan('Electric Cyan', Color(0xFF00E5FF)),
  emerald('Sovereign Emerald', Color(0xFF10B981)),
  amber('Cyber Amber', Color(0xFFF59E0B)),
  violet('Cosmic Violet', Color(0xFF8B5CF6)),
  rose('Sunset Rose', Color(0xFFF43F5E));

  final String label;
  final Color color;
  const AppAccentGlow(this.label, this.color);
}

class ThemeService extends ChangeNotifier {
  static const _palettePrefKey = 'aur_bhai_theme_palette';
  static const _accentPrefKey = 'aur_bhai_theme_accent';

  AppThemePalette _currentPalette = AppThemePalette.midnightCyber;
  AppAccentGlow _currentAccent = AppAccentGlow.cyan;

  AppThemePalette get currentPalette => _currentPalette;
  AppAccentGlow get currentAccent => _currentAccent;
  Color get accentColor => _currentAccent.color;

  ThemeService() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final palName = prefs.getString(_palettePrefKey);
      if (palName != null) {
        _currentPalette = AppThemePalette.values.firstWhere(
          (p) => p.name == palName,
          orElse: () => AppThemePalette.midnightCyber,
        );
      }
      final accName = prefs.getString(_accentPrefKey);
      if (accName != null) {
        _currentAccent = AppAccentGlow.values.firstWhere(
          (a) => a.name == accName,
          orElse: () => AppAccentGlow.cyan,
        );
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setPalette(AppThemePalette palette) async {
    if (_currentPalette == palette) return;
    _currentPalette = palette;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_palettePrefKey, palette.name);
  }

  Future<void> setAccent(AppAccentGlow accent) async {
    if (_currentAccent == accent) return;
    _currentAccent = accent;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentPrefKey, accent.name);
  }

  /// Generates the Flutter ThemeData for the current palette & accent.
  ThemeData buildThemeData() {
    final accent = _currentAccent.color;
    final isLight = _currentPalette == AppThemePalette.solarisLight;

    Color bg;
    Color surface;
    Color border;
    Color textPrimary;
    Color textSecondary;

    switch (_currentPalette) {
      case AppThemePalette.midnightCyber:
        bg = const Color(0xFF070A12);
        surface = const Color(0xFF0F172A);
        border = const Color(0xFF1E293B);
        textPrimary = const Color(0xFFF8FAFC);
        textSecondary = const Color(0xFF94A3B8);
        break;
      case AppThemePalette.warmObsidian:
        bg = const Color(0xFF121110);
        surface = const Color(0xFF1C1917);
        border = const Color(0xFF292524);
        textPrimary = const Color(0xFFFAF9F6);
        textSecondary = const Color(0xFFA8A29E);
        break;
      case AppThemePalette.deepTwilight:
        bg = const Color(0xFF0B0F19);
        surface = const Color(0xFF111827);
        border = const Color(0xFF1F2937);
        textPrimary = const Color(0xFFF9FAFB);
        textSecondary = const Color(0xFF9CA3AF);
        break;
      case AppThemePalette.matrixMint:
        bg = const Color(0xFF06120E);
        surface = const Color(0xFF0D1F18);
        border = const Color(0xFF13382C);
        textPrimary = const Color(0xFFECFDF5);
        textSecondary = const Color(0xFF6EE7B7);
        break;
      case AppThemePalette.solarisLight:
        bg = const Color(0xFFF8FAFC);
        surface = const Color(0xFFFFFFFF);
        border = const Color(0xFFE2E8F0);
        textPrimary = const Color(0xFF0F172A);
        textSecondary = const Color(0xFF64748B);
        break;
    }

    final brightness = isLight ? Brightness.light : Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      cardColor: surface,
      dividerColor: border,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: accent,
        onPrimary: isLight ? Colors.white : Colors.black,
        secondary: accent,
        onSecondary: isLight ? Colors.white : Colors.black,
        error: const Color(0xFFEF4444),
        onError: Colors.white,
        surface: surface,
        onSurface: textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: textPrimary,
        elevation: 0,
      ),
    );
  }
}

final themeServiceProvider = ChangeNotifierProvider<ThemeService>((ref) {
  return ThemeService();
});
