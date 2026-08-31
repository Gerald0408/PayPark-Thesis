import 'package:flutter/material.dart';

/// Minimal bar chart for a stat card's corner — no axes/labels, just
/// relative bar heights hinting at the trend across the day. The last bar
/// (the current/most-recent bucket) is drawn in [highlightColor] at full
/// opacity; the rest fade toward [color] based on their own height, the
/// same "today so far" emphasis a mechanical odometer-style dashboard
/// tile uses elsewhere in this app.
class BarSparkline extends StatelessWidget {
  const BarSparkline({
    super.key,
    required this.values,
    this.width = 90,
    this.height = 40,
    this.color = Colors.black,
    this.highlightColor,
    this.barWidth = 6,
    this.gap = 4,
  });

  final List<double> values;
  final double width;
  final double height;
  final Color color;
  final Color? highlightColor;
  final double barWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _BarSparklinePainter(
          values: values,
          color: color,
          highlightColor: highlightColor ?? color,
          barWidth: barWidth,
          gap: gap,
        ),
      ),
    );
  }
}

class _BarSparklinePainter extends CustomPainter {
  _BarSparklinePainter({
    required this.values,
    required this.color,
    required this.highlightColor,
    required this.barWidth,
    required this.gap,
  });

  final List<double> values;
  final Color color;
  final Color highlightColor;
  final double barWidth;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final safeMax = maxV <= 0 ? 1.0 : maxV;
    // A bucket with no data yet still gets a short stub instead of
    // vanishing entirely, so an empty chart doesn't read as a rendering
    // bug.
    const minFraction = 0.12;

    for (var i = 0; i < values.length; i++) {
      final isLast = i == values.length - 1;
      final fraction = (values[i] / safeMax).clamp(0.0, 1.0);
      final h = size.height * (minFraction + fraction * (1 - minFraction));
      final x = i * (barWidth + gap);
      if (x > size.width) break;
      final rect = RRect.fromLTRBR(
        x,
        size.height - h,
        x + barWidth,
        size.height,
        Radius.circular(barWidth / 2),
      );
      final paint = Paint()
        ..color = (isLast ? highlightColor : color)
            .withOpacity(isLast ? 1.0 : 0.28 + 0.32 * fraction);
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BarSparklinePainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.color != color ||
      oldDelegate.highlightColor != highlightColor;
}

/// Minimal trend line ("sparkline") for a stat card's corner — same
/// footprint and purpose as [BarSparkline], just a smoothed line instead
/// of bars, for a series that reads better as a continuous trend (e.g. a
/// running average) than as discrete buckets.
class LineSparkline extends StatelessWidget {
  const LineSparkline({
    super.key,
    required this.values,
    this.width = 90,
    this.height = 40,
    this.color = Colors.black,
    this.strokeWidth = 2.5,
  });

  final List<double> values;
  final double width;
  final double height;
  final Color color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _LineSparklinePainter(
          values: values,
          color: color,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _LineSparklinePainter extends CustomPainter {
  _LineSparklinePainter({
    required this.values,
    required this.color,
    required this.strokeWidth,
  });

  final List<double> values;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : maxV - minV;

    final dx = size.width / (values.length - 1);
    // Leave a little headroom top/bottom so the line never touches the
    // card's edges even at its min/max.
    final points = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(
          i * dx,
          size.height * 0.9 -
              ((values[i] - minV) / range) * size.height * 0.8,
        ),
    ];

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LineSparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
