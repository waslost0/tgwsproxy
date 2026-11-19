// Purpose: animated tunnel orb and its painter.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_colors.dart';
import '../connection_wm.dart';

class TunnelOrb extends StatefulWidget {
  const TunnelOrb({
    super.key,
    required this.active,
    required this.busy,
    required this.status,
  });

  final bool active;
  final bool busy;
  final ProxyStatus status;

  @override
  State<TunnelOrb> createState() => TunnelOrbState();
}

class TunnelOrbState extends State<TunnelOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 156,
      height: 156,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => CustomPaint(
                painter: OrbPainter(
                  progress: _controller.value,
                  active: widget.active,
                  busy: widget.busy,
                  primary: AppColors.primary,
                  secondary: AppColors.secondary,
                  outline: AppColors.outlineVariant,
                ),
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: widget.active
                    ? [AppColors.primary, AppColors.secondary]
                    : [AppColors.surfaceHigh, AppColors.surfaceContainer],
              ),
              boxShadow: widget.active
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.35),
                        blurRadius: 26,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              widget.busy
                  ? Icons.sync_rounded
                  : widget.active
                  ? Icons.shield_rounded
                  : Icons.power_settings_new_rounded,
              color: widget.active
                  ? AppColors.onPrimary
                  : AppColors.onSurfaceVariant,
              size: 30,
            ),
          ),
        ],
      ),
    );
  }
}

class OrbPainter extends CustomPainter {
  OrbPainter({
    required this.progress,
    required this.active,
    required this.busy,
    required this.primary,
    required this.secondary,
    required this.outline,
  });

  final double progress;
  final bool active;
  final bool busy;
  final Color primary;
  final Color secondary;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline.withValues(alpha: 0.55);
    canvas.drawCircle(center, 48, base);
    canvas.drawCircle(center, 62, base);
    canvas.drawCircle(
      center,
      76,
      base..color = outline.withValues(alpha: 0.28),
    );

    final angle = progress * math.pi * 2;
    if (active || busy) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [primary.withValues(alpha: 0.05), primary, secondary],
          transform: GradientRotation(angle),
        ).createShader(Rect.fromCircle(center: center, radius: 76));
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: 68),
        angle,
        math.pi * 1.15,
        false,
        arc,
      );
      for (var i = 0; i < 3; i++) {
        final dotAngle = angle + i * (math.pi * 2 / 3);
        final dot =
            center + Offset(math.cos(dotAngle), math.sin(dotAngle)) * 68;
        canvas.drawCircle(
          dot,
          3.2,
          Paint()..color = i == 0 ? primary : secondary,
        );
      }
    } else {
      for (var i = 0; i < 3; i++) {
        final dotAngle = -math.pi / 2 + i * (math.pi * 2 / 3);
        final dot =
            center + Offset(math.cos(dotAngle), math.sin(dotAngle)) * 68;
        canvas.drawCircle(dot, 2.4, Paint()..color = outline);
      }
    }
  }

  @override
  bool shouldRepaint(covariant OrbPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.active != active ||
      oldDelegate.busy != busy ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary;
}
