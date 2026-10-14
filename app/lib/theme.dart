import 'package:flutter/material.dart';

/// Second Look visual system: calm cobalt for trust, with clear signal colours for verdicts.
class SL {
  // Brand
  static const cobalt = Color(0xFF2346E0);
  static const cobaltSoft = Color(0xFFE6EBFF);
  static const ink = Color(0xFF0F1A2E);
  static const amber = Color(0xFFF2B33D);

  // Verdict signals (light)
  static const safe = Color(0xFF16804A);
  static const safeBg = Color(0xFFE3F4EA);
  static const warn = Color(0xFF9A5B00);
  static const warnBg = Color(0xFFFFF1D6);
  static const danger = Color(0xFFC0262D);
  static const dangerBg = Color(0xFFFDE8E8);

  // Verdict signals (dark)
  static const safeD = Color(0xFF7ED79B);
  static const safeBgD = Color(0xFF12301D);
  static const warnD = Color(0xFFFFCD6B);
  static const warnBgD = Color(0xFF352709);
  static const dangerD = Color(0xFFFF8F84);
  static const dangerBgD = Color(0xFF3A1613);

  static Color fg(BuildContext c, String level) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    switch (level) {
      case 'danger':
        return dark ? dangerD : danger;
      case 'warning':
        return dark ? warnD : warn;
      default:
        return dark ? safeD : safe;
    }
  }

  static Color bg(BuildContext c, String level) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    switch (level) {
      case 'danger':
        return dark ? dangerBgD : dangerBg;
      case 'warning':
        return dark ? warnBgD : warnBg;
      default:
        return dark ? safeBgD : safeBg;
    }
  }

  static IconData icon(String level) {
    switch (level) {
      case 'danger':
        return Icons.gpp_bad_rounded;
      case 'warning':
        return Icons.report_rounded;
      default:
        return Icons.verified_user_rounded;
    }
  }

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: cobalt,
      brightness: b,
      primary: dark ? const Color(0xFF8FA4FF) : cobalt,
      onPrimary: dark ? const Color(0xFF0B1120) : Colors.white,
      surface: dark ? const Color(0xFF141B2E) : Colors.white,
      onSurface: dark ? const Color(0xFFE9ECF5) : ink,
    );
    final bgColor = dark ? const Color(0xFF0B1120) : const Color(0xFFF3F5F9);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bgColor,
      appBarTheme: AppBarTheme(backgroundColor: bgColor, elevation: 0, scrolledUnderElevation: 0, centerTitle: false,
          titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: scheme.onSurface, letterSpacing: -0.3)),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF0F1628) : const Color(0xFFF7F8FB),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: dark ? const Color(0xFF26304A) : const Color(0xFFDCE1EC))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: dark ? const Color(0xFF26304A) : const Color(0xFFDCE1EC))),
        contentPadding: const EdgeInsets.all(16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: dark ? const Color(0xFF26315C) : cobaltSoft,
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.2),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        bodyLarge: TextStyle(fontSize: 16, height: 1.45),
        bodyMedium: TextStyle(fontSize: 14.5, height: 1.45),
      ),
    );
  }
}
