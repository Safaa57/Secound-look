import 'dart:ui' show FontVariation;

import 'package:flutter/material.dart';

/// Second Look visual system: a near-black navy ground, faint glass cards with a cool cyan hairline, one bright
/// cyan accent for primary actions and clear green / amber / red signal colours. Sora for headings and primary
/// buttons, Manrope for everything else. The app always runs in dark mode.
class SL {
  // ---- fonts (bundled in assets/fonts; Devanagari and Kannada fall back to the system fonts)
  static const display = 'Sora';
  static const body = 'Manrope';

  // ---- ground and text
  static const ground = Color(0xFF060912);
  static const text = Color(0xFFEAF2FF);
  static const textSecondary = Color(0xFFA9B8D0);
  static const textSoft = Color(0xFFCBD5E1);
  static const textMuted = Color(0xFF93A4BF);
  static const navFill = Color(0xEB0E1424); // rgba(14,20,36,.92)
  static const sheet = Color(0xFF0E1424);

  // ---- accent
  static const accent = Color(0xFF38E1FF);
  static const accentLight = Color(0xFF8BEFFF);
  static const accentDeep = Color(0xFF0E7490);
  static const onAccent = Color(0xFF04121A);
  static const teal = Color(0xFF2DD4BF);

  // ---- glass cards: white @4% with a cyan hairline rgba(140,220,255,.14)
  static const glass = Color(0x0AFFFFFF);
  static const glassStrong = Color(0x14FFFFFF);
  static const glassBorder = Color(0x248CDCFF);
  static const hairline = Color(0x14FFFFFF); // rgba(255,255,255,.08)
  static const radius = 20.0;

  // Older names, still used in a few places.
  static const bgTop = ground;
  static const bgBottom = ground;
  static const bgSolid = ground;
  static const cobalt = accentDeep;
  static const cobaltSoft = Color(0xFF0C2733);
  static const ink = ground;
  static const amber = Color(0xFFFBBF24);

  // ---- signals
  static const safeD = Color(0xFF34D399);
  static const safeLight = Color(0xFFBFF5DE);
  static const safeDeep = Color(0xFF0B1A17);
  static const warnD = Color(0xFFFBBF24);
  static const warnLight = Color(0xFFFDE68A);
  static const warnDeep = Color(0xFF221A08);
  static const dangerD = Color(0xFFF87171);
  static const dangerLight = Color(0xFFFECACA);
  static const dangerSoft = Color(0xFFFCA5A5);
  static const dangerDeep = Color(0xFF2A0E12);
  static const onDanger = Color(0xFF1A0507);

  static const safeBgD = Color(0x1F34D399);
  static const warnBgD = Color(0x1FFBBF24);
  static const dangerBgD = Color(0x24F87171);

  // Kept for old call sites; the app only uses the dark set.
  static const safe = safeD;
  static const safeBg = safeBgD;
  static const warn = warnD;
  static const warnBg = warnBgD;
  static const danger = dangerD;
  static const dangerBg = dangerBgD;

  /// Solid red for filled buttons; put [onDanger] text on it.
  static const dangerFill = dangerD;

  static String _lv(String level) => level == 'danger' || level == 'warning' ? level : 'safe';

  /// The signal colour for 'safe' | 'warning' | 'danger'.
  static Color fg(BuildContext c, String level) => fgOf(level);

  static Color fgOf(String level) {
    switch (_lv(level)) {
      case 'danger':
        return dangerD;
      case 'warning':
        return warnD;
      default:
        return safeD;
    }
  }

  /// A soft tint of the signal colour for backgrounds.
  static Color bg(BuildContext c, String level) {
    switch (_lv(level)) {
      case 'danger':
        return dangerBgD;
      case 'warning':
        return warnBgD;
      default:
        return safeBgD;
    }
  }

  /// Light text in the signal colour (headings on tinted surfaces).
  static Color pale(String level) {
    switch (_lv(level)) {
      case 'danger':
        return dangerLight;
      case 'warning':
        return warnLight;
      default:
        return safeLight;
    }
  }

  /// The very dark fill inside verdict circles.
  static Color deep(String level) {
    switch (_lv(level)) {
      case 'danger':
        return dangerDeep;
      case 'warning':
        return warnDeep;
      default:
        return safeDeep;
    }
  }

  /// Text colour on a filled signal-colour button.
  static Color on(String level) => _lv(level) == 'danger' ? onDanger : onAccent;

  static IconData icon(String level) {
    switch (level) {
      case 'danger':
        return Icons.gpp_bad_outlined;
      case 'warning':
        return Icons.gpp_maybe_outlined;
      default:
        return Icons.gpp_good_outlined;
    }
  }

  /// The simple mark shown inside verdict circles: ✓ / ! / ✕.
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

  /// The flat ground behind every screen.
  static const backdrop = BoxDecoration(color: ground);

  static const _weights = [
    FontWeight.w100,
    FontWeight.w200,
    FontWeight.w300,
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
    FontWeight.w900,
  ];

  /// The 'wght' axis for a weight, so the bundled variable fonts draw their real weight (not a synthesized bold).
  static List<FontVariation> wght(FontWeight w) {
    final i = _weights.indexOf(w);
    return [FontVariation('wght', i < 0 ? 400.0 : (i + 1) * 100.0)];
  }

  /// Heading text in Sora.
  static TextStyle h(double size, {Color color = text, FontWeight weight = FontWeight.w700, double? height, double? spacing}) =>
      TextStyle(fontFamily: display, fontSize: size, fontWeight: weight, fontVariations: wght(weight), color: color, height: height, letterSpacing: spacing);

  static TextStyle _sora(double size, {FontWeight weight = FontWeight.w700, double? height, double? spacing}) =>
      TextStyle(fontFamily: display, fontSize: size, fontWeight: weight, fontVariations: wght(weight), height: height, letterSpacing: spacing);

  static ThemeData light() => _base();
  static ThemeData dark() => _base();

  static ThemeData _base() {
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: const Color(0xFF0B2E3A),
      onPrimaryContainer: accentLight,
      secondary: teal,
      onSecondary: onAccent,
      secondaryContainer: const Color(0xFF0C2733),
      onSecondaryContainer: accentLight,
      tertiary: amber,
      error: dangerD,
      onError: onDanger,
      surface: const Color(0xFF0E1424),
      onSurface: text,
      onSurfaceVariant: textMuted,
      surfaceContainerLowest: ground,
      surfaceContainerLow: const Color(0xFF0A0F1C),
      surfaceContainer: const Color(0xFF0E1424),
      surfaceContainerHigh: const Color(0xFF121A2C),
      surfaceContainerHighest: const Color(0xFF172036),
      outline: const Color(0x3D8CDCFF),
      outlineVariant: glassBorder,
      surfaceTint: Colors.transparent,
    );
    final round16 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    final fieldBorder = OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: Color(0x338CDCFF)));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: body,
      colorScheme: scheme,
      scaffoldBackgroundColor: ground,
      canvasColor: ground,
      dividerColor: hairline,
      dividerTheme: const DividerThemeData(color: hairline, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        titleTextStyle: h(22),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: const Color(0x1AFFFFFF),
          disabledForegroundColor: const Color(0x80EAF2FF),
          minimumSize: const Size(0, 56),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: _sora(16.5),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size(0, 52),
          side: const BorderSide(color: Color(0x33FFFFFF)),
          backgroundColor: const Color(0x0DFFFFFF),
          shape: round16,
          textStyle: const TextStyle(fontFamily: body, fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent, textStyle: const TextStyle(fontFamily: body, fontWeight: FontWeight.w700)),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: text)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glass,
        hintStyle: const TextStyle(color: Color(0x99A9B8D0), fontWeight: FontWeight.w600),
        labelStyle: const TextStyle(color: textSecondary, fontWeight: FontWeight.w600),
        helperStyle: const TextStyle(color: textMuted),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: accent, width: 1.6)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : textMuted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : const Color(0x14FFFFFF)),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : const Color(0x3D8CDCFF)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: accent,
        checkmarkColor: onAccent,
        side: const BorderSide(color: Color(0x338CDCFF)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        labelStyle: TextStyle(
          fontFamily: body,
          fontWeight: FontWeight.w700,
          fontSize: 14,
          color: WidgetStateColor.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : text),
        ),
        secondaryLabelStyle: const TextStyle(fontFamily: body, fontWeight: FontWeight.w700, color: onAccent, fontSize: 14),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: sheet,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: glassBorder)),
        textStyle: const TextStyle(fontFamily: body, fontWeight: FontWeight.w600, color: text),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: sheet,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: Color(0x4D8CDCFF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF172036),
        contentTextStyle: const TextStyle(fontFamily: body, color: text, fontSize: 14.5, height: 1.35, fontWeight: FontWeight.w600),
        actionTextColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: glassBorder)),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textMuted,
        textColor: text,
        titleTextStyle: TextStyle(fontFamily: body, fontSize: 15.5, fontWeight: FontWeight.w700, color: text),
        subtitleTextStyle: TextStyle(fontFamily: body, fontSize: 13.5, color: textSecondary, height: 1.35),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: accent, selectionColor: Color(0x5538E1FF), selectionHandleColor: accent),
      textTheme: TextTheme(
        displaySmall: _sora(34, height: 1.1),
        headlineLarge: _sora(30, height: 1.12),
        headlineMedium: _sora(28, height: 1.15, spacing: -0.3),
        headlineSmall: _sora(23, height: 1.18),
        titleLarge: _sora(20),
        titleMedium: const TextStyle(fontFamily: body, fontSize: 16, fontWeight: FontWeight.w700),
        titleSmall: const TextStyle(fontFamily: body, fontSize: 14, fontWeight: FontWeight.w700),
        bodyLarge: const TextStyle(fontFamily: body, fontSize: 16, height: 1.45, fontWeight: FontWeight.w500),
        bodyMedium: const TextStyle(fontFamily: body, fontSize: 14.5, height: 1.45, fontWeight: FontWeight.w500),
        bodySmall: const TextStyle(fontFamily: body, fontSize: 12.5, height: 1.4, color: textMuted),
        labelLarge: const TextStyle(fontFamily: body, fontWeight: FontWeight.w700),
      ),
    );
  }
}
