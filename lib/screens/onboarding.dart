import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../legal/legal.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Four calm, swipeable slides (what it does, privacy, alerts for new numbers, control), each with a small
/// animated illustration drawn in Flutter, ending with the Terms / Privacy consent.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final pc = PageController();
  int page = 0;
  bool agreed = false;

  @override
  void dispose() {
    pc.dispose();
    super.dispose();
  }

  List<_Page> get pages => [
        _Page(
          art: const _ScanArt(),
          title: tr('Take a second look\nbefore you tap'),
          text: tr('Second Look checks SMS, links and calls for scam tricks: fake KYC alerts, UPI "receive money" traps, digital-arrest calls, fake couriers and look-alike websites.'),
          points: [tr('Clear verdicts: Safe, Suspicious or Likely scam'), tr('Plain-language reasons, not just a red label'), tr('What to do next, including one-tap 1930')],
        ),
        _Page(
          art: const _LockArt(),
          title: tr('Your messages never\nleave your phone'),
          text: tr('Second Look doesn\'t upload your contacts or messages. Checks run on the device. Only the optional Deep check sends a link you choose to be checked online.'),
          points: [tr('No contact uploads, no names database'), tr('No account or sign-up needed'), tr('Delete everything with one tap')],
        ),
        _Page(
          art: const _CallArt(),
          title: tr('Know who\'s calling\nand texting'),
          text: tr('Every SMS and call from a new number that Second Look checks is listed in Alerts, on this phone only.'),
          points: [tr('Mark any number: Block, Spam, Fraud or Safe'), tr('Add your own note to remember a caller'), tr('See everything you marked in one place')],
        ),
        _Page(
          art: const _ToggleArt(),
          title: tr('You\'re in control'),
          text: tr('SMS Shield and Call Shield stay OFF until you switch them on. Your phone will ask for permission, and you can switch them off any time.'),
          points: [tr('SMS Shield: checks new texts as they arrive'), tr('Call Shield: tells you who\'s calling while it rings'), tr('Pause either shield whenever you like')],
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final pages = this.pages;
    final last = page == pages.length - 1;
    final noMotion = MediaQuery.of(context).disableAnimations;
    final move = Duration(milliseconds: noMotion ? 1 : 320);
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(children: [
            const Align(
              alignment: Alignment.centerRight,
              child: Padding(padding: EdgeInsets.fromLTRB(0, 8, 12, 0), child: LanguageButton()),
            ),
            Expanded(
              child: PageView(
                controller: pc,
                onPageChanged: (i) => setState(() => page = i),
                children: pages,
              ),
            ),
            Semantics(
              label: tr('Page {n} of {total}', {'n': page + 1, 'total': pages.length}),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < pages.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: i == page ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface.withAlpha(40),
                        borderRadius: BorderRadius.circular(4)),
                  ),
              ]),
            ),
            if (last)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 20, 0),
                child: ConsentBox(value: agreed, onChanged: (v) => setState(() => agreed = v)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Row(children: [
                if (!last)
                  TextButton(
                    onPressed: () => pc.animateToPage(pages.length - 1, duration: move, curve: Curves.easeOut),
                    child: Text(tr('Skip')),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: last ? (agreed ? widget.onDone : null) : () => pc.nextPage(duration: move, curve: Curves.easeOut),
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: Text(last ? tr('Get started') : tr('Next'))),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.art, required this.title, required this.text, required this.points});
  final Widget art;
  final String title, text;
  final List<String> points;
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(24, 12, 24, 12), children: [
        Center(
          child: Container(
            width: 240,
            height: 190,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: RadialGradient(colors: [SL.accent.withAlpha(40), SL.accent.withAlpha(0)]),
            ),
            child: SizedBox(width: 220, height: 170, child: art),
          ),
        ),
        const SizedBox(height: 18),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        Text(text, style: TextStyle(fontSize: 15.5, height: 1.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(180))),
        const SizedBox(height: 18),
        Panel(
          child: Column(children: [
            for (final p in points)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Icon(Icons.check_circle_rounded, color: SL.fg(context, 'safe'), size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Text(p, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))),
                ]),
              ),
          ]),
        ),
      ]);
}

// ---------------------------------------------------------------------------------------------------------------
// Illustrations: simple shapes drawn in Flutter, gently looping. They hold still when animations are turned off.

/// Loops a 0..1 value for an illustration; stays at [still] when the phone asks for reduced motion.
abstract class _ArtState<T extends StatefulWidget> extends State<T> with SingleTickerProviderStateMixin<T> {
  late final AnimationController c = AnimationController(vsync: this, duration: period);
  Duration get period => const Duration(milliseconds: 2600);
  double get still => 0.6;
  bool _set = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final noMotion = MediaQuery.of(context).disableAnimations;
    if (noMotion) {
      c.stop();
      c.value = still;
    } else if (!_set || !c.isAnimating) {
      c.repeat();
    }
    _set = true;
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Widget paint(CustomPainter Function(double t, ColorScheme cs, bool dark) painter) => AnimatedBuilder(
        animation: c,
        builder: (context, _) => CustomPaint(
          painter: painter(c.value, Theme.of(context).colorScheme, Theme.of(context).brightness == Brightness.dark),
        ),
      );
}

/// A message card with a scanning line; a warning badge pops up when the scan passes the link.
class _ScanArt extends StatefulWidget {
  const _ScanArt();
  @override
  State<_ScanArt> createState() => _ScanArtState();
}

class _ScanArtState extends _ArtState<_ScanArt> {
  @override
  Widget build(BuildContext context) => paint((t, cs, dark) => _ScanPainter(t, cs, SL.fg(context, 'danger'), SL.fg(context, 'safe')));
}

class _ScanPainter extends CustomPainter {
  _ScanPainter(this.t, this.cs, this.danger, this.safe);
  final double t;
  final ColorScheme cs;
  final Color danger, safe;

  @override
  void paint(Canvas canvas, Size s) {
    // Phone body
    final phone = RRect.fromRectAndRadius(Rect.fromCenter(center: s.center(Offset.zero), width: s.width * 0.5, height: s.height * 0.98), const Radius.circular(22));
    canvas.drawRRect(phone, Paint()..color = cs.primary.withAlpha(22));
    canvas.drawRRect(phone, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = cs.primary.withAlpha(120));
    final left = phone.left + 14, right = phone.right - 14;
    // Message bubble
    final bubble = RRect.fromRectAndRadius(Rect.fromLTRB(left, phone.top + 28, right, phone.top + 98), const Radius.circular(12));
    canvas.drawRRect(bubble, Paint()..color = cs.surface);
    final line = Paint()
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(left + 12, bubble.top + 18), Offset(right - 20, bubble.top + 18), line..color = cs.onSurface.withAlpha(60));
    canvas.drawLine(Offset(left + 12, bubble.top + 34), Offset(right - 34, bubble.top + 34), line..color = cs.onSurface.withAlpha(60));
    canvas.drawLine(Offset(left + 12, bubble.top + 50), Offset(right - 44, bubble.top + 50), line..color = cs.primary.withAlpha(170)); // the link
    // Scan line sweeping down
    final y = phone.top + 20 + (phone.height - 40) * (t < 0.7 ? t / 0.7 : 1.0);
    if (t < 0.72) {
      canvas.drawRect(
        Rect.fromLTRB(phone.left + 6, y - 14, phone.right - 6, y),
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [cs.primary.withAlpha(0), cs.primary.withAlpha(70)])
              .createShader(Rect.fromLTRB(0, y - 14, s.width, y)),
      );
      canvas.drawLine(Offset(phone.left + 6, y), Offset(phone.right - 6, y), Paint()
        ..strokeWidth = 2
        ..color = cs.primary);
    }
    // Warning badge appears once the line passes the link
    final linkY = bubble.top + 50;
    final shown = ((y - linkY) / 30).clamp(0.0, 1.0).toDouble() * (t > 0.92 ? (1 - (t - 0.92) / 0.08) : 1.0);
    if (shown > 0) {
      final c = Offset(phone.right - 6, bubble.top + 4);
      final r = 15.0 * Curves.easeOutBack.transform(shown.clamp(0.0, 1.0).toDouble());
      canvas.drawCircle(c, r, Paint()..color = danger);
      final tp = TextPainter(
        text: TextSpan(text: '!', style: TextStyle(color: Colors.white, fontSize: r * 1.3, fontWeight: FontWeight.w900)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
    // Second, safe bubble
    final b2 = RRect.fromRectAndRadius(Rect.fromLTRB(left, phone.top + 110, right - 20, phone.top + 140), const Radius.circular(12));
    canvas.drawRRect(b2, Paint()..color = cs.surface);
    canvas.drawCircle(Offset(b2.right - 12, b2.center.dy), 6, Paint()..color = safe.withAlpha(t > 0.6 ? 220 : 60));
  }

  @override
  bool shouldRepaint(_ScanPainter o) => o.t != t || o.cs != cs;
}

/// A phone with a lock and a calm pulse; little "data" dots bounce back at the edge and never leave.
class _LockArt extends StatefulWidget {
  const _LockArt();
  @override
  State<_LockArt> createState() => _LockArtState();
}

class _LockArtState extends _ArtState<_LockArt> {
  @override
  Widget build(BuildContext context) => paint((t, cs, dark) => _LockPainter(t, cs, SL.fg(context, 'safe')));
}

class _LockPainter extends CustomPainter {
  _LockPainter(this.t, this.cs, this.safe);
  final double t;
  final ColorScheme cs;
  final Color safe;

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    // Pulse rings
    for (var k = 0; k < 2; k++) {
      final p = (t + k * 0.5) % 1.0;
      canvas.drawCircle(c, 40 + p * 44, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = cs.primary.withAlpha((90 * (1 - p)).round()));
    }
    // Phone
    final phone = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 70, height: 118), const Radius.circular(16));
    canvas.drawRRect(phone, Paint()..color = cs.surface);
    canvas.drawRRect(phone, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = cs.primary.withAlpha(150));
    // Dots orbit inside the phone
    for (var k = 0; k < 3; k++) {
      final a = (t + k / 3) * math.pi * 2;
      canvas.drawCircle(c + Offset(math.cos(a) * 22, math.sin(a) * 40), 4, Paint()..color = cs.primary.withAlpha(150));
    }
    // Lock
    final body = RRect.fromRectAndRadius(Rect.fromCenter(center: c + const Offset(0, 8), width: 30, height: 24), const Radius.circular(6));
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - 9, c.dy - 3)
        ..lineTo(c.dx - 9, c.dy - 10)
        ..arcToPoint(Offset(c.dx + 9, c.dy - 10), radius: const Radius.circular(9))
        ..lineTo(c.dx + 9, c.dy - 3),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = safe,
    );
    canvas.drawRRect(body, Paint()..color = safe);
  }

  @override
  bool shouldRepaint(_LockPainter o) => o.t != t || o.cs != cs;
}

/// An incoming call card that gently rings, with a row of mark buttons lighting up in turn.
class _CallArt extends StatefulWidget {
  const _CallArt();
  @override
  State<_CallArt> createState() => _CallArtState();
}

class _CallArtState extends _ArtState<_CallArt> {
  @override
  Widget build(BuildContext context) =>
      paint((t, cs, dark) => _CallPainter(t, cs, [SL.fg(context, 'danger'), SL.fg(context, 'warning'), SL.fg(context, 'danger'), SL.fg(context, 'safe')]));
}

class _CallPainter extends CustomPainter {
  _CallPainter(this.t, this.cs, this.marks);
  final double t;
  final ColorScheme cs;
  final List<Color> marks;

  @override
  void paint(Canvas canvas, Size s) {
    final wobble = math.sin(t * math.pi * 12) * (t < 0.35 ? 2.5 : 0);
    canvas.save();
    canvas.translate(wobble, 0);
    final card = RRect.fromRectAndRadius(Rect.fromLTWH(10, 14, s.width - 20, 76), const Radius.circular(18));
    canvas.drawRRect(card, Paint()..color = cs.surface);
    canvas.drawRRect(card, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = cs.primary.withAlpha(90));
    // Avatar with ringing waves
    final av = Offset(card.left + 38, card.center.dy);
    canvas.drawCircle(av, 20, Paint()..color = cs.primary.withAlpha(40));
    final phonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = cs.primary;
    for (var k = 1; k <= 2; k++) {
      final on = t < 0.35 && ((t * 8).floor() % 2 == k % 2);
      canvas.drawArc(Rect.fromCircle(center: av, radius: 20.0 + k * 7), -0.7, 1.4, false, phonePaint..color = cs.primary.withAlpha(on ? 200 : 40));
    }
    canvas.drawCircle(av, 8, Paint()..color = cs.primary);
    // Number lines
    final line = Paint()
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(av.dx + 34, av.dy - 10), Offset(card.right - 26, av.dy - 10), line..color = cs.onSurface.withAlpha(110));
    canvas.drawLine(Offset(av.dx + 34, av.dy + 10), Offset(card.right - 60, av.dy + 10), line..color = cs.onSurface.withAlpha(50));
    canvas.restore();
    // Mark buttons light up one after the other
    const n = 4;
    final w = (s.width - 20 - (n - 1) * 8) / n;
    for (var i = 0; i < n; i++) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(10 + i * (w + 8), 112, w, 34), const Radius.circular(999));
      final active = t > 0.4 && ((t - 0.4) / 0.15).floor() == i;
      canvas.drawRRect(r, Paint()..color = marks[i].withAlpha(active ? 70 : 22));
      canvas.drawRRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2.5 : 1.2
        ..color = marks[i].withAlpha(active ? 255 : 110));
      canvas.drawCircle(Offset(r.left + 14, r.center.dy), 5, Paint()..color = marks[i]);
    }
  }

  @override
  bool shouldRepaint(_CallPainter o) => o.t != t || o.cs != cs;
}

/// Two shield switches that slide on, one after the other.
class _ToggleArt extends StatefulWidget {
  const _ToggleArt();
  @override
  State<_ToggleArt> createState() => _ToggleArtState();
}

class _ToggleArtState extends _ArtState<_ToggleArt> {
  @override
  double get still => 0.8;
  @override
  Widget build(BuildContext context) => paint((t, cs, dark) => _TogglePainter(t, cs, SL.fg(context, 'safe')));
}

class _TogglePainter extends CustomPainter {
  _TogglePainter(this.t, this.cs, this.safe);
  final double t;
  final ColorScheme cs;
  final Color safe;

  @override
  void paint(Canvas canvas, Size s) {
    for (var i = 0; i < 2; i++) {
      final start = 0.15 + i * 0.25;
      final v = Curves.easeInOut.transform(((t - start) / 0.2).clamp(0.0, 1.0).toDouble()) * (t > 0.92 ? (1 - (t - 0.92) / 0.08) : 1.0);
      final top = 22.0 + i * 70;
      final row = RRect.fromRectAndRadius(Rect.fromLTWH(10, top, s.width - 20, 54), const Radius.circular(16));
      canvas.drawRRect(row, Paint()..color = cs.surface);
      canvas.drawRRect(row, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = cs.onSurface.withAlpha(40));
      // icon square
      final sq = RRect.fromRectAndRadius(Rect.fromLTWH(row.left + 12, top + 11, 32, 32), const Radius.circular(10));
      canvas.drawRRect(sq, Paint()..color = Color.lerp(cs.onSurface.withAlpha(25), safe.withAlpha(60), v)!);
      // text line
      canvas.drawLine(Offset(sq.right + 12, top + 27), Offset(row.right - 80, top + 27), Paint()
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = cs.onSurface.withAlpha(70));
      // switch track + thumb
      final track = RRect.fromRectAndRadius(Rect.fromLTWH(row.right - 64, top + 13, 50, 28), const Radius.circular(14));
      canvas.drawRRect(track, Paint()..color = Color.lerp(cs.onSurface.withAlpha(45), safe, v)!);
      canvas.drawCircle(Offset(track.left + 14 + 22 * v, track.center.dy), 10, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_TogglePainter o) => o.t != t || o.cs != cs;
}
