import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens — light canvas, white elevated cards, teal/emerald accent.
///
/// Every screen and widget in this app reads its colors from here rather
/// than hardcoding hex values, so this file is the single place that
/// decides the palette. Accent family matches the referenced water-utility
/// app: deep forest teal for primary actions/headers, bright emerald for
/// active/interactive highlights, white text/icons on top of both (not
/// near-black — a saturated teal reads cleaner with white on it).
class YosColors {
  YosColors._();

  // ---- Canvas & ink ----
  static const Color bg = Color(0xFFF2F9F7); // faint mint-tinted canvas
  static const Color bgDeep = Color(0xFFFFFFFF); // bottom nav bar
  static const Color surface = Color(0xFFFFFFFF); // card fill
  static const Color surfaceHigh = Color(0xFFFFFFFF); // raised card / menu
  static const Color ink = Color(0xFF16161A); // primary text
  static const Color sub = Color(0xFF6B6B72); // secondary text (AA on white)

  /// Text sitting directly on the canvas. Same as [ink] here since the
  /// whole UI is one light appearance — kept so screens can be explicit.
  static const Color onNavy = Color(0xFF16161A);
  static const Color onNavySub = Color(0xFF6B6B72);

  // ---- Teal / emerald spectrum ----
  static const Color accent = Color(0xFF12A585); // primary emerald teal
  static const Color accentDeep = Color(0xFF0D6B57); // pressed / header / CTA
  static const Color accentSoft = Color(0xFF6FD9BE); // highlights
  static const Color accentGlow = Color(0x3312A585); // 20% glow

  // ---- Card palette ----
  // Down to two pastel greens — the mid "sage" shade (0xFFE7F0DC) was
  // flagged as unwanted, so it's retired rather than replaced.
  static const Color mint = Color(0xFFE2F5EC); // coolest, blue-leaning
  static const Color moss = Color(0xFFDEEBD1); // deepest, most saturated

  // Legacy aliases from the earlier six-shade (then three-shade) palette
  // — collapsed onto the two above so every existing call site keeps
  // compiling without reintroducing a retired shade.
  static const Color pistachio = moss;
  static const Color fern = moss;
  static const Color seafoam = mint;
  static const Color sage = moss;

  // ---- Semantic accents ----
  // Darkened from the neon dark-mode versions so they hold AA contrast
  // as text/icon color directly on a light surface.
  static const Color good = Color(0xFF2E9E4F); // success green (leafier than accent's teal)
  static const Color warn = Color(0xFFB25E00); // caution amber
  static const Color bad = Color(0xFFD8352B); // destructive red

  // Health-bar tiers, matching the reference's score bars.
  static const Color healthHigh = good;
  static const Color healthMid = Color(0xFF8A8F1E);
  static const Color healthLow = Color(0xFFB2540A);

  // ---- Legacy aliases ----
  static const Color emerald = good;
  static const Color amber = warn;
  static const Color danger = bad;
  static const Color textPrimary = ink;
  static const Color textSecondary = sub;
  static const Color glassBorder = Color(0x14000000); // black 8%
  static const Color glassFill = Color(0x08000000); // black 3%
  static const Color gridLine = Color(0x0D000000);
}

/// Rotating card tints so lists alternate.
const List<Color> kPastels = [
  YosColors.mint,
  YosColors.moss,
];

Color pastelAt(int i) => kPastels[i % kPastels.length];

class YosTheme {
  YosTheme._();

  /// Kept as `light()` so main.dart needs no change.
  static ThemeData light() => _dispatch();

  static ThemeData dark() => _dispatch();

  static ThemeData _dispatch() {
    final base = ThemeData.light(useMaterial3: true);

    final text = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: YosColors.ink,
      displayColor: YosColors.ink,
    );

    final textTheme = text.copyWith(
      displayLarge: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.6,
        height: 1.0,
        color: YosColors.ink,
      ),
      displayMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
        height: 1.05,
        color: YosColors.ink,
      ),
      headlineMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.8,
        color: YosColors.ink,
      ),
      titleMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: YosColors.ink,
      ),
      bodyMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w400,
        color: YosColors.ink,
      ),
      // Small, wide-tracked labels for statuses and column headers.
      labelSmall: GoogleFonts.inter(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: YosColors.sub,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: YosColors.sub,
      ),
    );

    return base.copyWith(
      scaffoldBackgroundColor: YosColors.bg,
      canvasColor: YosColors.bg,

      colorScheme: const ColorScheme.light(
        primary: YosColors.accent,
        // Near-black, not white: accent is a mid-brightness teal (~3:1
        // against white, ~6.7:1 against near-black) — dark text is the
        // AA-safe pairing here. White belongs on the darker accentDeep
        // instead (see BreathingGlowButton's default color).
        onPrimary: Color(0xFF0A0A0B),
        secondary: YosColors.accentSoft,
        onSecondary: Color(0xFF0A0A0B),
        surface: YosColors.surface,
        onSurface: YosColors.ink,
        error: YosColors.bad,
        onError: Colors.white,
      ),

      textTheme: textTheme,

      iconTheme: const IconThemeData(color: YosColors.ink, size: 22),

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: YosColors.ink,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: YosColors.ink,
        ),
        iconTheme: const IconThemeData(color: YosColors.ink),
      ),

      dividerTheme: const DividerThemeData(
        color: YosColors.glassBorder,
        thickness: 1,
        space: 20,
      ),

      // Orange pill CTAs.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: YosColors.accent,
          foregroundColor: const Color(0xFF0A0A0B),
          disabledBackgroundColor: const Color(0xFFE4E4E7),
          disabledForegroundColor: const Color(0xFF9A9AA2),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: YosColors.ink,
          backgroundColor: YosColors.surface,
          side: const BorderSide(color: Color(0x1F000000)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: YosColors.accent,
          textStyle: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Search fields: white fill, hairline border, softly rounded.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: YosColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: YosColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: YosColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: YosColors.bad),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: YosColors.bad, width: 1.5),
        ),
        labelStyle: GoogleFonts.inter(
          color: YosColors.sub,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        hintStyle: GoogleFonts.inter(
          color: YosColors.sub,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
        prefixIconColor: YosColors.sub,
      ),

      // Status chips: white fill, orange when selected.
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: YosColors.surfaceHigh,
        selectedColor: YosColors.accent,
        side: const BorderSide(color: YosColors.glassBorder),
        labelStyle: GoogleFonts.inter(
          color: YosColors.ink,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: GoogleFonts.inter(
          color: const Color(0xFF0A0A0B),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),

      cardTheme: CardThemeData(
        color: YosColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: YosColors.glassBorder),
        ),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: YosColors.surface,
        surfaceTintColor: Colors.transparent,
      ),

      dialogTheme: const DialogThemeData(
        backgroundColor: YosColors.surface,
        surfaceTintColor: Colors.transparent,
      ),

      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: YosColors.bgDeep,
        selectedItemColor: YosColors.accent,
        unselectedItemColor: YosColors.sub,
        type: BottomNavigationBarType.fixed,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: YosColors.surfaceHigh,
        contentTextStyle: GoogleFonts.inter(
          color: YosColors.ink,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: YosColors.glassBorder),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: YosColors.accent,
        linearTrackColor: Color(0xFFE4E4E7),
        circularTrackColor: Color(0xFFE4E4E7),
      ),

      listTileTheme: const ListTileThemeData(
        textColor: YosColors.ink,
        iconColor: YosColors.accent,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? YosColors.accent
                : YosColors.sub),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? YosColors.accent.withOpacity(0.3)
                : const Color(0xFFE4E4E7)),
      ),
    );
  }
}

/// Conventional soft drop shadow for white cards on the light canvas —
/// a faint teal bloom underneath for brand warmth, plus a low-alpha black
/// shadow for actual elevation (66% black would read as a heavy halo on
/// a light background, so this is much softer than the dark-mode version).
const List<BoxShadow> kSoftShadow = [
  BoxShadow(
    color: Color(0x1412A585),
    blurRadius: 28,
    spreadRadius: -8,
    offset: Offset(0, 6),
  ),
  BoxShadow(
    color: Color(0x14000000),
    blurRadius: 16,
    offset: Offset(0, 4),
  ),
];

/// Teal gradient for hero panels and emphasised CTAs.
const LinearGradient kAccentGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [YosColors.accentSoft, YosColors.accent, YosColors.accentDeep],
);

/// Ambient backdrop glow behind hero illustrations.
const RadialGradient kAmbientGlow = RadialGradient(
  center: Alignment.topCenter,
  radius: 1.2,
  colors: [Color(0x2612A585), Color(0x00F2F9F7)],
);