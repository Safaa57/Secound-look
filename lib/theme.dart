import 'package:flutter/material.dart';

/// Second Look visual system ("dark premium"): deep navy backdrop, glass-like cards, a cyan accent for
/// primary actions and clear green / amber / red signal colours for verdicts. The app always runs in dark mode.
class SL {
  // Brand / accent
  static const accent = Color(0xFF22D3EE); // cyan: primary actions, focus, links
  static const accentDeep = Color(0xFF0891B2);
  static const onAccent = Color(0xFF03141A);
  static const teal = Color(0xFF2DD4BF);

  // Backdrop
  static const bgTop = Color(0xFF070B14);
  static const bgBottom = Color(0xFF0B1220);
  static const bgSolid = Color(0xFF090F1B); // sub-pages (a solid colour keeps page transitions clean)
  static const text = Color(0xFFF1F5F9);
  static const textMuted = Color(0xFF9AA4B5);

  // Glass surfaces
  static final glass = Colors.white.withAlpha(13);
  static final glassStrong = Colors.white.withAlpha(20);
  static final glassBorder = Colors.white.withAlpha(24);
  static const radius = 20.0;

  // Older names, still used in a few places.
  static const cobalt = accentDeep;
  static const cobaltSoft = Color(0xFF123241);
  static const ink = bgBottom;
  static const amber = Color(0xFFF59E0B);

  // Verdict signals (light; kept for completeness, the app uses the dark set)
  static const safe = Color(0xFF15803D);
  static const safeBg = Color(0xFFE3F4EA);
  static const warn = Color(0xFF9A5B00);
  static const warnBg = Color(0xFFFFF1D6);
  static const danger = Color(0xFFC0262D);
  static const dangerBg = Color(0xFFFDE8E8);

  // Verdict signals (dark). All pass WCAG AA as text on the navy backdrop.
  static const safeD = Color(0xFF22C55E);
  static const safeBgD = Color(0x2E22C55E);
  static const warnD = Color(0xFFF59E0B);
  static const warnBgD = Color(0x2EF59E0B);
  static const dangerD = Color(0xFFEF4444);
  static const dangerBgD = Color(0x30EF4444);

  /// Solid red for filled buttons with white text (darker than [dangerD] so the label stays readable).
  static const dangerFill = Color(0xFFDC2626);

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

  /// The simple mark shown inside verdict rings: ✓ / ! / ✕.
  static IconData mark(String level) {
    switch (level) {
      case 'danger':
        return Icons.close_rounded;
      case 'warning':
        return Icons.priority_high_rounded;
      default:
        return Icons.check_rounded;
    }
  }

  /// The navy gradient behind the main tabs, splash and onboarding.
  static const backdrop = BoxDecoration(
    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [bgTop, bgBottom]),
  );

  static ThemeData light() => _base();
  static ThemeData dark() => _base();

  static ThemeData _base() {
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: const Color(0xFF0E3A47),
      onPrimaryContainer: const Color(0xFFCFF7FF),
      secondary: teal,
      onSecondary: onAccent,
      secondaryContainer: const Color(0xFF123241),
      onSecondaryContainer: const Color(0xFFCFF7FF),
      tertiary: amber,
      error: dangerD,
      onError: Colors.white,
      surface: const Color(0xFF111A2B),
      onSurface: text,
      onSurfaceVariant: textMuted,
      surfaceContainerLowest: bgTop,
      surfaceContainerLow: const Color(0xFF0E1626),
      surfaceContainer: const Color(0xFF121B2D),
      surfaceContainerHigh: const Color(0xFF162034),
      surfaceContainerHighest: const Color(0xFF1B263C),
      outline: const Color(0xFF3A4760),
      outlineVariant: const Color(0xFF253047),
      surfaceTint: Colors.transparent,
    );
    final round = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    final fieldBorder = OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: glassBorder));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bgSolid,
      canvasColor: bgSolid,
      dividerColor: Colors.white.withAlpha(20),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: text, letterSpacing: -0.3),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: Colors.white.withAlpha(22),
          disabledForegroundColor: Colors.white.withAlpha(110),
          minimumSize: const Size(0, 54),
          shape: round,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.1),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size(0, 50),
          side: BorderSide(color: Colors.white.withAlpha(40)),
          backgroundColor: Colors.white.withAlpha(8),
          shape: round,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent, textStyle: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withAlpha(10),
        hintStyle: TextStyle(color: text.withAlpha(110)),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: accent, width: 1.6)),
        contentPadding: const EdgeInsets.all(16),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : const Color(0xFF8A94A6)),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : Colors.white.withAlpha(22)),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : Colors.white.withAlpha(50)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withAlpha(10),
        selectedColor: accent.withAlpha(46),
        side: BorderSide(color: Colors.white.withAlpha(30)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600, color: text),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xF20A101C),
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withAlpha(40),
        height: 68,
        iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(color: s.contains(WidgetState.selected) ? accent : textMuted, size: 25)),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600, color: s.contains(WidgetState.selected) ? text : textMuted)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF111A2B),
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1B263C),
        contentTextStyle: const TextStyle(color: text, fontSize: 14.5, height: 1.35),
        actionTextColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(iconColor: textMuted, textColor: text),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.12),
        headlineSmall: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.4, height: 1.15),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.1),
        bodyLarge: TextStyle(fontSize: 16, height: 1.45),
        bodyMedium: TextStyle(fontSize: 14.5, height: 1.45),
        labelLarge: TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}
