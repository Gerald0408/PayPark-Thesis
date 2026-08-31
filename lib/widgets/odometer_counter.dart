import 'package:flutter/material.dart';

/// Mechanical odometer: each character slides vertically when its value
/// changes, like a physical rolling counter. Works for numbers with
/// separators/prefixes (₱1,240.00) — non-digit chars swap without rolling.
class OdometerCounter extends StatelessWidget {
  const OdometerCounter({
    super.key,
    required this.value,
    this.style,
    this.duration = const Duration(milliseconds: 650),
  });

  final String value;
  final TextStyle? style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final chars = value.split('');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chars.length; i++)
          _OdometerChar(
            key: ValueKey('slot_$i${chars.length}'),
            char: chars[i],
            style: style,
            duration: duration,
            // Stagger digits slightly for the cascading mechanical feel.
            delay: Duration(milliseconds: 40 * (chars.length - i)),
          ),
      ],
    );
  }
}

class _OdometerChar extends StatelessWidget {
  const _OdometerChar({
    super.key,
    required this.char,
    required this.duration,
    required this.delay,
    this.style,
  });

  final String char;
  final TextStyle? style;
  final Duration duration;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(char);
          final slide = Tween<Offset>(
            begin: incoming ? const Offset(0, 1) : const Offset(0, -1),
            end: Offset.zero,
          ).animate(animation);
          return SlideTransition(position: slide, child: child);
        },
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.center,
          children: [...previousChildren, if (currentChild != null) currentChild],
        ),
        child: Text(char, key: ValueKey(char), style: style),
      ),
    );
  }
}
