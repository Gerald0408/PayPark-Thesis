import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Soft pastel blob that blooms under taps — playful, subtle.
/// Keeps the name TouchGlowOverlay so screen imports don't change.
class TouchGlowOverlay extends StatefulWidget {
  const TouchGlowOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<TouchGlowOverlay> createState() => _TouchGlowOverlayState();
}

class _TouchGlowOverlayState extends State<TouchGlowOverlay>
    with SingleTickerProviderStateMixin {
  Offset? _pos;
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500));

  void _bloom(Offset p) {
    setState(() => _pos = p);
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _bloom(e.localPosition),
      child: Stack(
        children: [
          widget.child,
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                if (_pos == null || _c.isDismissed || _c.isCompleted) {
                  return const SizedBox.shrink();
                }
                final t = Curves.easeOut.transform(_c.value);
                return CustomPaint(
                  size: Size.infinite,
                  painter: _BlobPainter(_pos!, t),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.pos, this.t);
  final Offset pos;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = YosColors.sage.withOpacity(0.35 * (1 - t));
    canvas.drawCircle(pos, 30 + 60 * t, paint);
  }

  @override
  bool shouldRepaint(_BlobPainter old) => old.t != t || old.pos != pos;
}

/// Chunky deep-teal pill button. Fires a shine sweep across the surface
/// on tap — silent when idle, glossy confirmation on press.
class BreathingGlowButton extends StatefulWidget {
  const BreathingGlowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = YosColors.accentDeep,
    this.foreground = Colors.white,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final Color color;
  final Color foreground;

  @override
  State<BreathingGlowButton> createState() => _BreathingGlowButtonState();
}

class _BreathingGlowButtonState extends State<BreathingGlowButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _shine = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  void _fireShine() {
    _shine.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) {
        setState(() => _pressed = false);
        _fireShine();
        widget.onPressed();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutBack,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 62,
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(999),
              boxShadow: kSoftShadow,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Label + icon
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(widget.icon, color: widget.foreground, size: 22),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: widget.foreground,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
                // Shine sweep overlay — a diagonal light streak that
                // slides from left-off-screen to right-off-screen on tap.
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _shine,
                      builder: (context, _) {
                        if (_shine.isDismissed) {
                          return const SizedBox.shrink();
                        }
                        final t = Curves.easeOut.transform(_shine.value);
                        return LayoutBuilder(
                          builder: (context, c) {
                            final w = c.maxWidth;
                            // Slide the streak from -w to +w.
                            final dx = -w + (2 * w) * t;
                            return Transform.translate(
                              offset: Offset(dx, 0),
                              child: Transform.rotate(
                                angle: -0.35, // slight diagonal
                                child: Container(
                                  width: 60,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        widget.foreground.withOpacity(0.0),
                                        widget.foreground.withOpacity(0.55),
                                        widget.foreground.withOpacity(0.0),
                                      ],
                                      stops: const [0.0, 0.5, 1.0],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sync status chip — friendly pill instead of neon badge.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, required this.online, this.pendingCount = 0});
  final bool online;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final Color bgc = online ? YosColors.mint : YosColors.pistachio;
    final label = online
        ? (pendingCount > 0 ? 'Syncing $pendingCount' : 'All synced')
        : 'Offline${pendingCount > 0 ? ' · $pendingCount saved' : ''}';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bgc,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
              size: 15, color: YosColors.ink),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  color: YosColors.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

/// Staggered pop-in entrance — give every list/grid item a springy arrival.
class PopIn extends StatefulWidget {
  const PopIn({super.key, required this.child, this.delayMs = 0});
  final Widget child;
  final int delayMs;

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 550));

  @override
  void initState() {
    super.initState();
    // Reduce Motion: skip the staggered slide/scale entrance entirely and
    // land on the settled state, instead of just speeding it up.
    if (WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations) {
      _c.value = 1;
      return;
    }
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: _c.value.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - curved.value)),
          child: Transform.scale(
            scale: 0.92 + 0.08 * curved.value,
            child: child,
          ),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Pulsing placeholder rectangle for skeleton loading states — used in
/// place of a spinner wherever the eventual content's shape is already
/// known, so the list doesn't jump layout when data arrives.
/// Freezes at a fixed opacity when Reduce Motion is enabled.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = 6,
  });
  final double? width;
  final double height;
  final double borderRadius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void initState() {
    super.initState();
    if (!WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final opacity = reduceMotion ? 0.6 : 0.35 + 0.35 * _c.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: YosColors.surfaceHigh.withOpacity(opacity),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
        );
      },
    );
  }
}

/// Animated ring progress (like the reference's circular meters).
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    this.size = 76,
    this.stroke = 9,
    this.color = YosColors.ink,
    this.track = Colors.white,
    this.child,
  });

  final double value; // 0..1
  final double size;
  final double stroke;
  final Color color;
  final Color track;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: 1,
                strokeWidth: stroke,
                valueColor: AlwaysStoppedAnimation(track),
              ),
            ),
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: v,
                strokeWidth: stroke,
                strokeCap: StrokeCap.round,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            if (child != null) child!,
          ],
        ),
      ),
    );
  }
}
