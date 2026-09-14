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
      // RepaintBoundary: isolates this card's press-scale animation into
      // its own compositing layer instead of repainting/recompositing
      // whatever's around it on every tick — see PopIn's matching comment
      // in glow_effects.dart for why that's what leaves a visible "trace"
      // behind on the Windows desktop GPU backend.
      child: RepaintBoundary(
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack, // springy pop
          child: Container(
            padding: widget.padding,
            decoration: BoxDecoration(
              color: widget.color ?? YosColors.surface,
              borderRadius: radius,
              // Always shadowed, not just when color is unset: a card with
              // an explicit pastel/accent fill (e.g. _NavTile's
              // YosColors.surface) can sit close enough in tone to the page
              // background — especially in the gold theme, where canvas and
              // card fills are both warm pale colors — that without a
              // shadow it has no visible edge at all.
              boxShadow: kSoftShadow,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Little decorative sparkle/star, like the reference UI's accents.
class Sparkle extends StatelessWidget {
  const Sparkle({super.key, this.size = 18, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.auto_awesome, size: size, color: color ?? YosColors.ink);
}
