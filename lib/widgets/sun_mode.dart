import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/light_controller.dart';

/// Applies sun-mode overrides to the whole subtree: bumps up font size,
/// forces max-contrast text, thickens button borders. Rebuild whenever
/// LightController flips.
class SunModeSwitcher extends StatefulWidget {
  const SunModeSwitcher({super.key, required this.child});
  final Widget child;

  @override
  State<SunModeSwitcher> createState() => _SunModeSwitcherState();
}

class _SunModeSwitcherState extends State<SunModeSwitcher> {
  @override
  void initState() {
    super.initState();
    LightController.instance.addListener(_onLight);
    LightController.instance.start();
    // Collectors' larger text: only this wrapper rebuilds on a role
    // change (the screens below are kept, not remounted).
    YosColors.role.addListener(_onLight);
  }

  void _onLight() => setState(() {});

  @override
  void dispose() {
    LightController.instance.removeListener(_onLight);
    YosColors.role.removeListener(_onLight);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sun = LightController.instance.sunMode;
    final baseMediaQuery = MediaQuery.of(context);
    final baseTheme = Theme.of(context);
    // Max-contrast text against whichever canvas is actually live: pure
    // black reads great on light mode's white canvas but turns invisible
    // on dark mode's near-black one, so this has to track YosColors.isDark
    // rather than always forcing black.
    final highContrast = YosColors.isDark ? Colors.white : Colors.black;
    final onHighContrast = YosColors.isDark ? Colors.black : Colors.white;

    // Always wraps in the same MediaQuery/Theme structure — only the DATA
    // varies with `sun`, never whether these ancestors exist at all.
    // The previous version returned `widget.child` directly (skipping
    // both wrappers) whenever sun mode was off, which — since the
    // ambient light sensor can flip `sun` at literally any moment,
    // independent of whatever screen or action is running — structurally
    // added/removed these InheritedWidgets from the tree app-wide. Every
    // screen depends on Theme.of/MediaQuery.of, so that unmount was a
    // global trigger for Flutter's "'_dependents.isEmpty': is not true"
    // crash, unrelated to whatever else happened to be on screen when it
    // fired. Keeping the wrapper structure constant and only swapping
    // the data lets InheritedWidget's own update mechanism handle the
    // change safely, the way it's designed to.
    // Collectors get 10% larger text by default (easier at the curb, on
    // older phones); sun mode adds its own boost on top. Builds on the
    // phone's own text-size setting rather than replacing it.
    final collector = YosColors.role.value == ThemeRole.collector;
    final factor = (collector ? 1.1 : 1.0) * (sun ? 1.14 : 1.0);
    final base = baseMediaQuery.textScaler.scale(1);
    return MediaQuery(
      data: factor == 1.0
          ? baseMediaQuery
          : baseMediaQuery.copyWith(
              textScaler: TextScaler.linear(base * factor)),
      child: Theme(
        data: sun
            ? baseTheme.copyWith(
                textTheme: baseTheme.textTheme.apply(
                  bodyColor: highContrast,
                  displayColor: highContrast,
                ),
                colorScheme: baseTheme.colorScheme.copyWith(
                  primary: highContrast,
                  onPrimary: onHighContrast,
                ),
              )
            : baseTheme,
        child: widget.child,
      ),
    );
  }
}

/// Header button that shows current mode and toggles manual override.
/// Long-press cycles auto on/off.
class SunModeButton extends StatefulWidget {
  const SunModeButton({super.key});

  @override
  State<SunModeButton> createState() => _SunModeButtonState();
}

class _SunModeButtonState extends State<SunModeButton> {
  @override
  void initState() {
    super.initState();
    LightController.instance.addListener(_onLight);
  }

  void _onLight() => setState(() {});

  @override
  void dispose() {
    LightController.instance.removeListener(_onLight);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = LightController.instance;
    final active = c.sunMode;
    return GestureDetector(
      onTap: () => c.setManual(!active),
      onLongPress: () => c.toggleAuto(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFFEEA6) : Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                active
                    ? Icons.wb_sunny_rounded
                    : Icons.brightness_medium_rounded,
                size: 15,
                color: active ? const Color(0xFF7A5B00) : YosColors.ink),
            const SizedBox(width: 6),
            Text(
              active ? 'Sun mode' : 'Auto',
              style: TextStyle(
                color: active ? const Color(0xFF7A5B00) : YosColors.ink,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (!c.autoEnabled) ...[
              const SizedBox(width: 4),
              Icon(Icons.lock_rounded, size: 10, color: YosColors.sub),
            ],
          ],
        ),
      ),
    );
  }
}
