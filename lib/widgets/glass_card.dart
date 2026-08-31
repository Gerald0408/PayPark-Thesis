import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Chunky rounded card in the playful pastel style.
/// Class keeps the name `GlassCard` so existing imports don't break.
/// Pass a [color] for a pastel fill; defaults to white with a soft shadow.
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius = 28,
    this.color,
    this.glowColor, // legacy param, ignored
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double borderRadius;
  final Color? color;
  final Color? glowColor;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    return GestureDetector(
      onTapDown:
          widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapCancel:
          widget.onTap == null ? null : () => setState(() => _pressed = false),
      onTapUp: widget.onTap == null
          ? null
          : (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            },
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack, // springy pop
        child: Container(
          padding: widget.padding,
          decoration: BoxDecoration(
            color: widget.color ?? Colors.white,
            borderRadius: radius,
            boxShadow: widget.color == null ? kSoftShadow : const [],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Little decorative sparkle/star, like the reference UI's accents.
class Sparkle extends StatelessWidget {
  const Sparkle({super.key, this.size = 18, this.color = YosColors.ink});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.auto_awesome, size: size, color: color);
}
