import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens — a six-stop navy-to-white blue palette (see the "blue"
/// comments below), replacing every green (lime, then cream) this file
/// used to carry in both modes. Unlike lime/cream, this palette's own
/// brand stops are the *dark* end (deep navy/royal blue) rather than the
/// light end, so — unlike the old lime/cream setup — the primary surface
/// needs *light* text on it in light mode, and dark mode's primary reaches
/// for the palette's pale end instead so it still pops against a dark
/// canvas. See [onAccent] below for how that plays out.
///
/// Every screen and widget in this app reads its colors from here rather
/// than hardcoding hex values, so this file is the single place that
/// decides the palette — sign-up, register, profile, printer settings,
/// dashboard, everything reads the same tokens, so a change here is a
/// change everywhere.
class YosColors {
  YosColors._();

  // ---- Light/dark mode ----
  // The app is light-mode only now (the toggle was removed by request) —
  // [_dark] stays false permanently. Left as a flag rather than deleting
  // every dark-branch color/ternary below outright: those still compile
  // and always resolve to their light side, and gutting them is a much
  // larger, purely-cosmetic change than what removing the toggle called
  // for.
  static const bool _dark = false;
  static bool get isDark => _dark;

  // ---- Super Admin colors ----
  // The Super Admin's whole app is gold (header, buttons, highlights, a warm
  // background); Admins and Collectors keep plain navy. Set by
  // RoleColors (widgets/role_colors.dart) once the signed-in role is
  // known, which then repaints the app in place — nothing is reloaded.
  static final ValueNotifier<bool> superAdmin = ValueNotifier(false);
  static bool get _gold => superAdmin.value;

  // ---- Canvas & ink (brightness-aware) ----
  // Every neutral below is now a blue-tinted equivalent of what it
  // replaced — light mode's used to be warm-cream-neutral, dark mode's
  // still carried a faint green cast left over from the original lime
  // palette (their green channel read highest of the three even though
  // they read as "just gray"). bgLight is the given palette's #D0E3FF —
  // every screen besides the dashboard (which paints its own gradient
  // backdrop over this) shows this directly as its page background.
  // mintLight/mossLight below reuse the palette's other pale stops
  // directly; the rest here are derived to match, since the given palette
  // doesn't name a neutral-gray or a dark-canvas stop.
  static const Color bgLight = Color(0xFFF2F4F8); // design's light gray
  static const Color bgDark = Color(0xFF10141F); // derived dark navy-black
  static Color get bg =>
      _dark ? bgDark : (_gold ? const Color(0xFFF6F2E8) : bgLight);

  static const Color bgDeepLight = Color(0xFFFFFFFF); // bottom nav bar
  static const Color bgDeepDark = Color(0xFF171D30);
  static Color get bgDeep => _dark ? bgDeepDark : bgDeepLight;

  static const Color surfaceLight = Color(0xFFFFFFFF); // card fill
  static const Color surfaceDark = Color(0xFF171D30); // one step above bg
  static Color get surface => _dark ? surfaceDark : surfaceLight;

  static const Color surfaceHighLight = Color(0xFFFFFFFF); // raised card / menu
  static const Color surfaceHighDark = Color(0xFF202A44);
  static Color get surfaceHigh => _dark ? surfaceHighDark : surfaceHighLight;

  static const Color inkLight = Color(0xFF1B1B1B); // near-black, unaffected
  static const Color inkDark = Color(0xFFE9EDF5); // slightly blue-white
  static Color get ink => _dark ? inkDark : inkLight;

  // Slate blue-gray, not a warm gray — kept in the same cool family as the
  // rest of this palette instead of clashing against it.
  static const Color subLight = Color(0xFF5B6478); // design's slate gray
  static const Color subDark = Color(0xFF9AA6C2); // light slate blue-gray
  static Color get sub => _dark ? subDark : subLight;

  /// Neutral divider/fill tone. Not wired into [glassBorder]/[gridLine]
  /// below (those stay alpha-based hairlines), but a real light-neutral
  /// fill any screen can reach for instead of inventing one inline.
  static const Color hairlineLight = Color(0xFFE3E7EF); // pale gray
  static const Color hairlineDark = Color(0xFF2A3350); // dark blue-gray
  static Color get hairline => _dark ? hairlineDark : hairlineLight;

  /// Text sitting directly on the canvas. Same as [ink]/[sub] here since
  /// the whole UI is one appearance per mode — kept so screens can be
  /// explicit.
  static Color get onNavy => ink;
  static Color get onNavySub => sub;

  // ---- Brand accent spectrum (brightness-aware) ----
  // This palette's own brand stops sit at its *dark* end, unlike lime and
  // cream before it, whose brand stops were both light. Light mode uses
  // the palette's two darkest colors as accent/accentDeep directly
  // (#334EAC royal blue, #081F5C deep navy) — a dark-on-dark pair, since
  // both need light (not dark) text on top; see [onAccent]. Dark mode
  // flips to the palette's paler end instead (#D0E3FF/#7096D1), the same
  // way the old lime accent needed to be bright to pop against a dark
  // canvas — those two still pair with dark ink on top, same as before.
  //
  // accentSoft is meant across this app as "a pale highlight that pairs
  // with a fixed dark badge/icon on top" (see theme.dart's onSecondary
  // below) — it has to stay pale in *both* modes for that pairing to
  // hold, same as it always has, regardless of which end of the palette
  // the primary accent itself now sits at.
  static const Color accentDeepLight = Color(0xFF0F2260); // design's deep navy
  static const Color accentLight = Color(0xFF14296B); // design's navy
  static const Color accentSoftLight = Color(0xFFE8ECF7); // pale navy wash

  static const Color accentDeepDark = Color(0xFF7096D1); // medium blue
  static const Color accentDark = Color(0xFFD0E3FF); // pale bright blue
  static const Color accentSoftDark = Color(0xFFF9FCFF); // palest wash

  // Super Admin: gold (dark enough for white text) instead of navy.
  static Color get accent =>
      _dark ? accentDark : (_gold ? const Color(0xFF8C6D0F) : accentLight);
  // Super Admin: deep gold (headers, badges) — the whole app gold.
  static Color get accentDeep => _dark
      ? accentDeepDark
      : (_gold ? const Color(0xFF5E4808) : accentDeepLight);
  static Color get accentSoft => _dark
      ? accentSoftDark
      : (_gold ? const Color(0xFFFBF3DC) : accentSoftLight);

  /// 20%-alpha version of the current mode's [accent] — derived so it
  /// always tracks whichever accent is live.
  static Color get accentGlow => accent.withValues(alpha: 0.2);

  /// Text/icon color for content sitting on [accent]/[accentDeep]. Mode-
  /// aware now, unlike every palette before this one: light mode's accent
  /// pair is dark (navy/royal blue), so it needs white on top; dark mode's
  /// is pale, so it keeps the dark ink every previous palette used
  /// unconditionally here.
  static Color get onAccent => _dark ? const Color(0xFF1B1B1B) : Colors.white;

  /// Text/icon color for content sitting on [accentSoft] specifically —
  /// separate from [onAccent] because accentSoft stays pale in both modes
  /// while accent/accentDeep no longer do, so the two surfaces need
  /// different foregrounds in light mode now. Always dark ink, in both
  /// modes, matching accentSoft's own always-pale shape.
  static Color get onAccentSoft => const Color(0xFF1B1B1B);

  // ---- Card palette (brightness-aware) ----
  // Down to two pastel tints — the mid "sage" shade was flagged as
  // unwanted, so it's retired rather than replaced. These pair with
  // dynamic [ink] text/icons on top of them (badge icons, chip labels),
  // so they have to invert too — a fixed light pastel would leave
  // dark-mode's light ink illegible on top of it, which is why mintDark/
  // mossDark stay dark navy tints even though dark mode's own accent
  // pair moved to the pale end of this palette — these two are canvas-
  // relative card tints, not accent-relative. Light values reuse the
  // given palette's own pale stops directly, between accentSoftLight and
  // accentLight in saturation, the same "paler/deeper" shape this pair
  // has always used.
  static const Color mintLight = Color(0xFFF7F8FB); // palest gray
  static const Color mintDark = Color(0xFF16224A); // muted dark navy
  static Color get mint =>
      _dark ? mintDark : (_gold ? const Color(0xFFFFFCF4) : mintLight);

  static const Color mossLight = Color(0xFFE6EAF5); // pale blue-gray
  static const Color mossDark = Color(0xFF081F5C); // deep navy (palette stop)
  static Color get moss =>
      _dark ? mossDark : (_gold ? const Color(0xFFF3E8C8) : mossLight);

  // Legacy aliases from the earlier six-shade (then three-shade) palette
  // — collapsed onto the two above so every existing call site keeps
  // compiling without reintroducing a retired shade.
  static Color get pistachio => moss;
  static Color get fern => moss;
  static Color get seafoam => mint;
  static Color get sage => moss;

  // ---- Semantic accents ----
  // Deliberately kept off the brand accent palette: success/caution/error
  // need to read as their own thing at a glance, not blend in as "more
  // brand lime". Left as green/amber/red rather than retuned for the lime
  // theme. `bad` is Paynex's kNegative — the one semantic color the source
  // file does define ("reserved for money out, overdue fees, destructive
  // actions. Nothing else."); good/warn aren't covered by it, so they're
  // unchanged.
  static const Color good = Color(0xFF2E9E4F); // success green
  static const Color warn = Color(0xFFB25E00); // caution amber
  static const Color bad = Color(0xFFF1373C); // kNegative

  // Health-bar tiers, matching the reference's score bars.
  static const Color healthHigh = good;
  static const Color healthMid = Color(0xFF8A8F1E);
  static const Color healthLow = Color(0xFFB2540A);

  // Pale/muted badge backgrounds for [bad]/[warn] events (e.g.
  // AuditScreen's failed-login, removed-Face-ID, and demoted-admin
  // badges) — same "pale tint in light, deep muted tint in dark" shape
  // [mint]/[moss] use above, paired with dynamic [ink] icons on top.
  // These used to be a single hardcoded hex that only worked in light
  // mode: paired with ink's near-white dark-mode color, the icon on top
  // was nearly invisible against an unchanged pale background.
  static const Color badSoftLight = Color(0xFFFBE8E6); // pale red tint
  static const Color badSoftDark = Color(0xFF4A231F); // deep muted red-brown
  static Color get badSoft => _dark ? badSoftDark : badSoftLight;

  static const Color warnSoftLight = Color(0xFFFDECD1); // pale amber tint
  static const Color warnSoftDark = Color(0xFF4A3316); // deep muted amber
  static Color get warnSoft => _dark ? warnSoftDark : warnSoftLight;

  // Same shape again, for [good] events — added because [mint] (the
  // token AuditScreen's _style() originally reached for) stopped being
  // green at all once this palette's earlier lime/cream swaps repurposed
  // every mint/seafoam/pistachio/sage/moss token to a blue pastel — a
  // "connection restored" badge using it was visually indistinguishable
  // from every neutral badge next to it, not a green success state.
  static const Color goodSoftLight = Color(0xFFE3F5E7); // pale green tint
  static const Color goodSoftDark = Color(0xFF1E3A24); // deep muted green
  static Color get goodSoft => _dark ? goodSoftDark : goodSoftLight;

  // ---- Legacy aliases ----
  static const Color emerald = good;
  static const Color amber = warn;
  static const Color danger = bad;
  static Color get textPrimary => ink;
  static Color get textSecondary => sub;

  // Borders/fills over a surface: black-based hairlines read fine on the
  // light surface but vanish on the dark one, so these flip to white-based
  // instead of just changing opacity.
  static Color get glassBorder =>
      _dark ? const Color(0x1FFFFFFF) : const Color(0x14000000);
  static Color get glassFill =>
      _dark ? const Color(0x14FFFFFF) : const Color(0x08000000);
  static Color get gridLine =>
      _dark ? const Color(0x14FFFFFF) : const Color(0x0D000000);
}

/// Rotating card tints so lists alternate.
List<Color> get kPastels => [YosColors.mint, YosColors.moss];

Color pastelAt(int i) => kPastels[i % kPastels.length];

class YosTheme {
  YosTheme._();

  /// Always the light variant, regardless of the current toggle — for the
  /// rare case something explicitly wants it.
  static ThemeData light() => _dispatch(dark: false);

  /// Always the dark variant, regardless of the current toggle.
  static ThemeData dark() => _dispatch(dark: true);

  /// Whichever variant [YosColors.isDark] currently says — this is what
  /// the app itself should build with, so it tracks the live toggle.
  static ThemeData current() => _dispatch(dark: YosColors.isDark);

  static ThemeData _dispatch({required bool dark}) {
    final base = dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);

    final bgColor = YosColors.bg; // warm cream for the Super Admin
    final bgDeepColor = dark ? YosColors.bgDeepDark : YosColors.bgDeepLight;
    final surfaceColor = dark ? YosColors.surfaceDark : YosColors.surfaceLight;
    final surfaceHighColor =
        dark ? YosColors.surfaceHighDark : YosColors.surfaceHighLight;
    final inkColor = dark ? YosColors.inkDark : YosColors.inkLight;
    final subColor = dark ? YosColors.subDark : YosColors.subLight;
    final borderColor =
        dark ? const Color(0x1FFFFFFF) : const Color(0x14000000);
    final disabledBg = dark ? const Color(0xFF2A313C) : const Color(0xFFE4E4E7);
    final disabledFg = dark ? const Color(0xFF6B7280) : const Color(0xFF9A9AA2);

    final text = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: inkColor,
      displayColor: inkColor,
    );

    final textTheme = text.copyWith(
      displayLarge: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.6,
        height: 1.0,
        color: inkColor,
      ),
      displayMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
        height: 1.05,
        color: inkColor,
      ),
      headlineMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.8,
        color: inkColor,
      ),
      titleMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: inkColor,
      ),
      bodyMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w400,
        color: inkColor,
      ),
      // Small, wide-tracked labels for statuses and column headers.
      labelSmall: GoogleFonts.inter(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: subColor,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: subColor,
      ),
    );

    // onPrimary via YosColors.onAccent rather than inlined here directly,
    // so a future palette where dark mode's accent isn't also bright (see
    // onAccent's own comment) only needs that one getter updated.
    final colorScheme = dark
        ? ColorScheme.dark(
            primary: YosColors.accent,
            onPrimary: YosColors.onAccent,
            secondary: YosColors.accentSoft,
            onSecondary: YosColors.onAccentSoft,
            surface: surfaceColor,
            onSurface: inkColor,
            error: YosColors.bad,
            onError: Colors.white,
          )
        : ColorScheme.light(
            primary: YosColors.accent,
            onPrimary: YosColors.onAccent,
            secondary: YosColors.accentSoft,
            onSecondary: YosColors.onAccentSoft,
            surface: surfaceColor,
            onSurface: inkColor,
            error: YosColors.bad,
            onError: Colors.white,
          );

    return base.copyWith(
      scaffoldBackgroundColor: bgColor,
      canvasColor: bgColor,

      colorScheme: colorScheme,

      textTheme: textTheme,

      iconTheme: IconThemeData(color: inkColor, size: 22),

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: inkColor,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: inkColor,
        ),
        iconTheme: IconThemeData(color: inkColor),
      ),

      dividerTheme: DividerThemeData(
        color: borderColor,
        thickness: 1,
        space: 20,
      ),

      // Green pill CTAs — same near-black-on-accent pairing in both
      // modes (see colorScheme above).
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          disabledBackgroundColor: disabledBg,
          disabledForegroundColor: disabledFg,
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
          // onAccentSoft, not the mode-tracking inkColor: this button's
          // background is accentSoft, which stays pale in BOTH light and
          // dark mode by design (see its own comment below) — inkColor
          // flips to a near-white text color in dark mode, which made
          // this button's label unreadable against that still-pale
          // background (near-white text on near-white fill).
          // onAccentSoft is the fixed dark ink meant for exactly this.
          foregroundColor: YosColors.onAccentSoft,
          // accentSoft (a pale wash of the brand accent), not plain white —
          // a flat white button read as inert/unstyled next to the rest of
          // the app's colored surfaces. Still an outlined/secondary button,
          // so this stays the soft wash rather than the solid accent the
          // Quick Actions tiles use — that's reserved for primary actions.
          backgroundColor: YosColors.accentSoft,
          side: BorderSide(color: borderColor),
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
          foregroundColor: colorScheme.primary,
          textStyle: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Search fields: surface fill, hairline border, softly rounded.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceColor,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
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
          color: subColor,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        hintStyle: GoogleFonts.inter(
          color: subColor,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
        prefixIconColor: subColor,
      ),

      // Status chips: surface fill, green when selected.
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surfaceHighColor,
        selectedColor: colorScheme.primary,
        side: BorderSide(color: borderColor),
        labelStyle: GoogleFonts.inter(
          color: inkColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: GoogleFonts.inter(
          color: colorScheme.onPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),

      cardTheme: CardThemeData(
        color: surfaceColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        // Rounder corners app-wide, not the Material default (a flatter
        // ~4dp) — every dialog in the app should read as visibly rounded
        // now, matching the app's cards/buttons, whether or not it's been
        // individually rebuilt around the new header+action-button chrome.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: bgDeepColor,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: subColor,
        type: BottomNavigationBarType.fixed,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHighColor,
        contentTextStyle: GoogleFonts.inter(
          color: inkColor,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderColor),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: disabledBg,
        circularTrackColor: disabledBg,
      ),

      listTileTheme: ListTileThemeData(
        textColor: inkColor,
        iconColor: colorScheme.primary,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? colorScheme.primary : subColor),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? colorScheme.primary.withValues(alpha: 0.3)
                : disabledBg),
      ),
    );
  }
}

/// Light mode: a glowing accent-colored card halo — an even,
/// omnidirectional glow (offset near zero, no downward-cast "drop shadow"
/// look), plus a thin dark grounding shadow underneath for actual
/// elevation. Every card in the app shares this token (see [GlassCard]),
/// which is what makes a plain surface-colored card still read as a
/// distinct, lit box against the canvas instead of blending into it —
/// worth keeping regardless of how close [YosColors.surface] and
/// [YosColors.bg] happen to sit under whichever palette is live.
/// Thin, not thick: no positive spread and a tighter blur/alpha than the
/// first pass — with cards sitting close together (the quick-action
/// grid, side-by-side stat cards), a wide, strong glow on each one was
/// visibly bleeding into its neighbors' glow instead of reading as one
/// clean halo per card.
///
/// Dark mode: no glow at all, just a plain grounding shadow. The same
/// accent-colored halo (paired with a *white* shadow layer to stay
/// visible against a dark fill) didn't read as "a lit box" the way it
/// does in light mode — against a dark canvas it lit up every single
/// card with a distinct bright ring around it, which just looked like
/// unwanted highlighting on every box rather than natural elevation.
List<BoxShadow> get kSoftShadow => YosColors.isDark
    ? [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ]
    : [
        BoxShadow(
          color: YosColors.accent.withValues(alpha: 0.18),
          blurRadius: 12,
          spreadRadius: -1,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

/// Accent gradient for hero panels and emphasised CTAs — tracks whichever
/// palette (light or dark) is currently live, so it's a getter rather than
/// a fixed [LinearGradient] const.
LinearGradient get kAccentGradient => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [YosColors.accentSoft, YosColors.accent, YosColors.accentDeep],
    );

/// Ambient backdrop glow behind hero illustrations — same live-palette
/// reasoning as [kAccentGradient] above.
RadialGradient get kAmbientGlow => RadialGradient(
      center: Alignment.topCenter,
      radius: 1.2,
      colors: [
        YosColors.accent.withValues(alpha: 0.15),
        const Color(0x00F2F9F7),
      ],
    );
