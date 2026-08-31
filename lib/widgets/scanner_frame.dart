import 'package:flutter/material.dart';

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
  static const navyMid = Color(0xFF141B3D);
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
    final path = Path()
      ..addOval(Rect.fromLTWH(0, 0, size.width, size.height));
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

/// Stylized wireframe face icon — an oval outline with a landmark
/// crosshair, eyes, nose and mouth, drawn rather than a bundled image
/// asset so it stays crisp at any size and matches [FaceIdColors].
class FaceWireframeIcon extends StatelessWidget {
  const FaceWireframeIcon(
      {super.key, this.size = 140, this.color = FaceIdColors.accent});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size * 1.15),
        painter: _FaceWireframePainter(color: color),
      );
}

class _FaceWireframePainter extends CustomPainter {
  _FaceWireframePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final dot = Paint()..color = color;

    canvas.drawOval(Rect.fromLTWH(0, 0, size.width, size.height), line);
    canvas.drawLine(
        Offset(size.width / 2, 0), Offset(size.width / 2, size.height), line);
    canvas.drawLine(Offset(0, size.height * 0.42),
        Offset(size.width, size.height * 0.42), line);
    canvas.drawCircle(Offset(size.width * 0.32, size.height * 0.42), 2.5, dot);
    canvas.drawCircle(Offset(size.width * 0.68, size.height * 0.42), 2.5, dot);
    canvas.drawPath(
      Path()
        ..moveTo(size.width / 2, size.height * 0.42)
        ..lineTo(size.width * 0.44, size.height * 0.6)
        ..lineTo(size.width * 0.56, size.height * 0.6)
        ..close(),
      line,
    );
    canvas.drawLine(Offset(size.width * 0.38, size.height * 0.74),
        Offset(size.width * 0.62, size.height * 0.74), line);
  }

  @override
  bool shouldRepaint(covariant _FaceWireframePainter old) =>
      old.color != color;
}

/// Dark "FaceID" splash shown before the camera opens — wireframe icon,
/// title, a short description, and a "Get Started" CTA. [onClose] shows a
/// back/close affordance in the top-left when given (e.g. a back button
/// out of the whole flow); omit it where the caller already provides one.
class FaceIdIntro extends StatelessWidget {
  const FaceIdIntro({
    super.key,
    required this.description,
    required this.onGetStarted,
    this.onClose,
  });

  final String description;
  final VoidCallback onGetStarted;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [FaceIdColors.navyDeep, FaceIdColors.navyMid],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            if (onClose != null)
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                ),
              ),
            const Spacer(),
            const FaceWireframeIcon(),
            const SizedBox(height: 28),
            const Text('FaceID',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5)),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Text(description,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      height: 1.5,
                      fontWeight: FontWeight.w500)),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
              child: SizedBox(
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [FaceIdColors.accent, Color(0xFF0D6B57)]),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: onGetStarted,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text('Get Started',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
