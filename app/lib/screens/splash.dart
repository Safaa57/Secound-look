import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme.dart';

/// Short intro shown on every launch (about 1.4 s): the shield draws in with a soft glow, a lock closes,
/// three reassuring checks tick in, then it fades into the app. Tap anywhere to skip.
/// With "remove animations" switched on in the phone's accessibility settings, a still frame is shown briefly instead.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.status, required this.onDone});

  /// The app status (may still be loading). Used for the "Shields" line.
  final Map<String, dynamic>? status;
  final VoidCallback onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  bool _started = false;
  bool _done = false;
  Timer? _still;

  // Deep night-blue backdrop with the brand cobalt; works the same in light and dark mode.
  static const _top = Color(0xFF0B1328);
  static const _bottom = Color(0xFF15245C);
  static const _glow = Color(0xFF5B7BFF);
  static const _tick = SL.safeD;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      c.value = 1;
      _still = Timer(const Duration(milliseconds: 700), _finish);
    } else {
      c.forward().whenComplete(_finish);
    }
  }

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    widget.onDone();
  }

  @override
  void dispose() {
    _still?.cancel();
    c.dispose();
    super.dispose();
  }

  double _seg(double a, double b, [Curve curve = Curves.easeOutCubic]) {
    final v = ((c.value - a) / (b - a)).clamp(0.0, 1.0).toDouble();
    return curve.transform(v);
  }

  String _shieldsLine() {
    final s = widget.status;
    if (s == null) return tr('Shields: checking…');
    if (s['platform'] == 'web') return tr('Nothing you paste is uploaded');
    final sms = s['smsShield'] == true ? tr('ON') : tr('OFF');
    final call = s['callShield'] == true ? tr('ON') : tr('OFF');
    return tr('Shields: SMS {sms} / Call {call}', {'sms': sms, 'call': call});
  }

  @override
  Widget build(BuildContext context) {
    final web = widget.status?['platform'] == 'web';
    final rows = [
      web ? tr('Checks run in this browser') : tr('Checks run on this phone'),
      tr('Your data is encrypted'),
      _shieldsLine(),
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _finish,
      child: Semantics(
        label: 'Second Look',
        // A Material ancestor gives the texts a proper default style (no Scaffold here).
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_top, _bottom]),
            ),
            child: SafeArea(
              child: AnimatedBuilder(
                animation: c,
                builder: (context, _) {
                  final draw = _seg(0.0, 0.42);
                  final fill = _seg(0.28, 0.55);
                  final lock = _seg(0.42, 0.62, Curves.easeOutBack);
                  final title = _seg(0.40, 0.62);
                  return Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                          width: 150,
                          height: 168,
                          child: CustomPaint(painter: _ShieldPainter(draw: draw, fill: fill, lock: lock, glow: _glow)),
                        ),
                        const SizedBox(height: 18),
                        Opacity(
                          opacity: title,
                          child: Transform.translate(
                            offset: Offset(0, 8 * (1 - title)),
                            child: const Text('Second Look',
                                style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                          ),
                        ),
                        const SizedBox(height: 26),
                        for (var i = 0; i < rows.length; i++) _row(rows[i], _seg(0.56 + i * 0.12, 0.76 + i * 0.12)),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String text, double t) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - t)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 22, height: 22, child: CustomPaint(painter: _TickPainter(t, _tick))),
              const SizedBox(width: 10),
              Flexible(
                child: Text(text,
                    style: TextStyle(color: Colors.white.withAlpha(230), fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.3)),
              ),
            ]),
          ),
        ),
      );
}

/// The shield outline (drawn progressively), its soft glow and fill, and a padlock whose shackle drops shut.
class _ShieldPainter extends CustomPainter {
  _ShieldPainter({required this.draw, required this.fill, required this.lock, required this.glow});
  final double draw, fill, lock;
  final Color glow;

  static Path shield(Size s) {
    final w = s.width, h = s.height;
    return Path()
      ..moveTo(w * 0.5, h * 0.04)
      ..cubicTo(w * 0.62, h * 0.12, w * 0.78, h * 0.16, w * 0.92, h * 0.16)
      ..lineTo(w * 0.92, h * 0.48)
      ..cubicTo(w * 0.92, h * 0.74, w * 0.72, h * 0.88, w * 0.5, h * 0.97)
      ..cubicTo(w * 0.28, h * 0.88, w * 0.08, h * 0.74, w * 0.08, h * 0.48)
      ..lineTo(w * 0.08, h * 0.16)
      ..cubicTo(w * 0.22, h * 0.16, w * 0.38, h * 0.12, w * 0.5, h * 0.04)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = shield(size);
    final center = Offset(size.width / 2, size.height * 0.5);

    // Soft glow behind the shield.
    if (draw > 0) {
      canvas.drawCircle(
        center,
        size.width * 0.55,
        Paint()
          ..color = glow.withAlpha((90 * draw).round())
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 34),
      );
    }

    // Fill.
    if (fill > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [SL.cobalt.withAlpha((235 * fill).round()), const Color(0xFF1A33A8).withAlpha((235 * fill).round())],
          ).createShader(Offset.zero & size),
      );
    }

    // Outline, drawn in.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFBFCBFF);
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * draw), stroke);
    }

    // Padlock.
    if (lock > 0) {
      final o = lock.clamp(0.0, 1.0).toDouble();
      final w = size.width;
      final bodyW = w * 0.34, bodyH = w * 0.26;
      final bodyTop = size.height * 0.48;
      final body = RRect.fromRectAndRadius(Rect.fromLTWH(center.dx - bodyW / 2, bodyTop, bodyW, bodyH), Radius.circular(w * 0.05));
      final white = Paint()..color = Colors.white.withAlpha((255 * o).round());
      // Shackle starts raised (open) and drops into the body.
      final lift = (1 - lock) * w * 0.10;
      final r = bodyW * 0.30;
      final shackle = Path()
        ..moveTo(center.dx - r, bodyTop + 2 - lift)
        ..lineTo(center.dx - r, bodyTop - r * 0.55 - lift)
        ..arcToPoint(Offset(center.dx + r, bodyTop - r * 0.55 - lift), radius: Radius.circular(r))
        ..lineTo(center.dx + r, bodyTop + 2 - (lift > 0 ? lift * 1.6 : 0));
      canvas.drawPath(
        shackle,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.055
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withAlpha((255 * o).round()),
      );
      canvas.drawRRect(body, white);
      // Keyhole.
      final kh = Paint()..color = SL.cobalt.withAlpha((255 * o).round());
      canvas.drawCircle(Offset(center.dx, bodyTop + bodyH * 0.42), w * 0.03, kh);
      canvas.drawRect(Rect.fromCenter(center: Offset(center.dx, bodyTop + bodyH * 0.62), width: w * 0.022, height: bodyH * 0.3), kh);
    }
  }

  @override
  bool shouldRepaint(_ShieldPainter o) => o.draw != draw || o.fill != fill || o.lock != lock;
}

/// A circle with a tick that draws in.
class _TickPainter extends CustomPainter {
  _TickPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    if (t <= 0) return;
    final c = Offset(s.width / 2, s.height / 2);
    canvas.drawCircle(c, s.width / 2, Paint()..color = color.withAlpha((60 * t).round()));
    final tick = Path()
      ..moveTo(s.width * 0.28, s.height * 0.52)
      ..lineTo(s.width * 0.44, s.height * 0.68)
      ..lineTo(s.width * 0.74, s.height * 0.36);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    for (final m in tick.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * math.min(1.0, t * 1.3)), p);
    }
  }

  @override
  bool shouldRepaint(_TickPainter o) => o.t != t || o.color != color;
}
