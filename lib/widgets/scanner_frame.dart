import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Full-bleed camera preview that crops to fill its bounds (like
/// BoxFit.cover) instead of stretching. [CameraPreview] sizes itself via
/// an internal `AspectRatio` matching the camera's true aspect ratio, but
/// `AspectRatio` only works under *loose* constraints — every FaceID
/// screen puts its preview in a `Stack(fit: StackFit.expand)` so the dark
/// background fills edge-to-edge, which hands `CameraPreview` *tight*
/// full-screen constraints instead. Under a tight box there's only one
/// possible size, so `AspectRatio` can't honor its target ratio at all —
/// it just fills those exact bounds regardless of the camera's real
/// proportions, stretching whatever's in frame. That's most visible as an
/// oddly elongated face, especially away from the oval scan guide's
/// center where the eye notices the distortion most.
///
/// Fix: give `CameraPreview` a genuinely loose box first (via
/// [ConstrainedBox], so its own `AspectRatio` sizes itself correctly,
/// letterboxed within that box), then scale *that* correctly-proportioned
/// result up with [FittedBox]'s `BoxFit.cover` to fill whatever tight
/// bounds this widget itself receives — cropping the letterboxed overflow
/// instead of distorting the image, the same "cover" behavior an ordinary
/// camera app's live preview has.
class CoverCameraPreview extends StatelessWidget {
  const CoverCameraPreview({super.key, required this.controller});
  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.cover,
      child: ConstrainedBox(
        constraints: BoxConstraints.loose(const Size(2000, 2000)),
        child: CameraPreview(controller),
      ),
    );
  }
}

/// Green/dark-navy palette for the FaceID scan UI — deliberately its own
/// small palette rather than YosColors, since these screens go for a
/// dark sci-fi HUD look distinct from the rest of the (light) app. Accent
/// is bright mint (matches YosColors.accentSoft) rather than the app's
/// deeper brand green, so it still pops against the dark navy background
/// the way the old cyan did.
class FaceIdColors {
  FaceIdColors._();
  static const accent = Color(0xFF6FD9BE);
  static const navyDeep = Color(0xFF0B1330);
  static const good = Color(0xFF2E9E4F);
}

/// Oval scan decoration: a dashed oval outline plus (while [scanning]) a
/// glowing horizontal line that sweeps top-to-bottom, matching a
/// FaceID-style scan animation. Shows a success checkmark instead once
/// [success] flips true.
class FaceOvalScanner extends StatefulWidget {
  const FaceOvalScanner({
    super.key,
    required this.width,
    required this.height,
    required this.scanning,
    this.success = false,
  });

  final double width;
  final double height;
  final bool scanning;
  final bool success;

  @override
  State<FaceOvalScanner> createState() => _FaceOvalScannerState();
}

class _FaceOvalScannerState extends State<FaceOvalScanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _line = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    if (widget.scanning) _line.repeat();
  }

  @override
  void didUpdateWidget(covariant FaceOvalScanner old) {
    super.didUpdateWidget(old);
    if (widget.scanning && !old.scanning) {
      _line.repeat();
    } else if (!widget.scanning && old.scanning) {
      _line.stop();
    }
  }

  @override
  void dispose() {
    _line.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.success ? FaceIdColors.good : FaceIdColors.accent;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(widget.width, widget.height),
            painter: _DashedOvalPainter(color: color),
          ),
          if (widget.scanning && !widget.success)
            ClipOval(
              child: SizedBox(
                width: widget.width,
                height: widget.height,
                // RepaintBoundary: this repeats continuously for as long as
                // a scan runs (see initState/didUpdateWidget above) — same
                // "trace left behind" reasoning as PopIn's matching comment
                // in glow_effects.dart, isolating it so every tick doesn't
                // repaint/recomposite the rest of this full-screen camera
                // UI along with it.
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _line,
                    builder: (context, _) => Align(
                      alignment: Alignment(0, -1 + 2 * _line.value),
                      child: Container(
                        height: 3,
                        width: widget.width,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            FaceIdColors.accent.withOpacity(0),
                            FaceIdColors.accent,
                            FaceIdColors.accent.withOpacity(0),
                          ]),
                          boxShadow: [
                            BoxShadow(
                                color: FaceIdColors.accent.withOpacity(0.8),
                                blurRadius: 10),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.success) const ScanCheckmark(),
        ],
      ),
    );
  }
}

class _DashedOvalPainter extends CustomPainter {
  _DashedOvalPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    const dashLength = 8.0;
    const gapLength = 6.0;
    final path = Path()..addOval(Rect.fromLTWH(0, 0, size.width, size.height));
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashLength;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedOvalPainter old) => old.color != color;
}

/// Green success checkmark shown centered once a face capture/match
/// completes.
class ScanCheckmark extends StatelessWidget {
  const ScanCheckmark({super.key, this.size = 72});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: FaceIdColors.good,
      ),
      child: Icon(Icons.check_rounded, color: Colors.white, size: size * 0.55),
    );
  }
}

/// Large "N%" readout, a caption ("Scanning." / custom), and a rounded
/// progress bar underneath — the HUD readout below the oval scanner.
class ScanProgressBar extends StatelessWidget {
  const ScanProgressBar({
    super.key,
    required this.progress,
    this.caption,
    this.color = FaceIdColors.accent,
  });
  final double progress;
  final String? caption;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: Colors.white24,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 10),
          Text(caption!,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ],
    );
  }
}
