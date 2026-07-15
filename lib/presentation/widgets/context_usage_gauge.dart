import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Cursor-like circular estimate of context use (hollow → filled dark).
class ContextUsageGauge extends StatelessWidget {
  final int usedTokens;
  final int budgetTokens;
  final double size;

  const ContextUsageGauge({
    super.key,
    required this.usedTokens,
    required this.budgetTokens,
    this.size = 28,
  });

  double get _ratio {
    if (budgetTokens <= 0) return 0;
    return (usedTokens / budgetTokens).clamp(0.0, 1.0);
  }

  String get _label {
    String fmt(int t) {
      if (t >= 1000) return '${(t / 1000).toStringAsFixed(t >= 10000 ? 0 : 1)}K';
      return '$t';
    }
    return '${fmt(usedTokens)} / ${fmt(budgetTokens)}';
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Est. context $_label',
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _ContextRingPainter(ratio: _ratio),
          child: Center(
            child: Text(
              '${(_ratio * 100).round()}',
              style: TextStyle(
                color: Colors.white70,
                fontSize: math.max(8, size * 0.28),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextRingPainter extends CustomPainter {
  final double ratio;

  _ContextRingPainter({required this.ratio});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    final bg = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, bg);

    final fg = Paint()
      ..color = Color.lerp(Colors.white38, Colors.white, ratio)! 
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final fill = Paint()
      ..color = Colors.white.withValues(alpha: 0.12 + 0.55 * ratio)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 1.5, fill);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * ratio,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _ContextRingPainter oldDelegate) =>
      oldDelegate.ratio != ratio;
}
