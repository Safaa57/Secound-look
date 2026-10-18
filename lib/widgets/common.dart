import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme.dart';

/// Glass-like card used for every surface in the app: a faint white fill with a 1px light border.
/// (No blur: it would be costly inside long scrolling lists.)
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color, this.borderColor, this.onTap, this.gradient});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(SL.radius);
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? SL.glass) : null,
        gradient: gradient,
        borderRadius: r,
        border: Border.all(color: borderColor ?? SL.glassBorder),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(color: Colors.transparent, child: InkWell(borderRadius: r, onTap: onTap, child: box));
  }
}

/// The navy gradient behind a screen.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(decoration: SL.backdrop, child: child);
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.icon, this.trailing});
  final String text;
  final IconData? icon;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurface.withAlpha(165);
    return Padding(
      padding: EdgeInsets.fromLTRB(4, 24, 4, trailing == null ? 10 : 4),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 17, color: SL.accent), const SizedBox(width: 8)],
        Expanded(child: Text(text.toUpperCase(), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: c))),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Small coloured pill for verdicts and caller types.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, required this.fg, required this.bg, this.icon});
  final String text;
  final Color fg, bg;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: fg.withAlpha(70))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 5)],
          Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12.5)),
        ]),
      );
}

/// A rounded square with a tinted icon (tools, list rows, settings sections).
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, required this.color, this.size = 44});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withAlpha(34),
          borderRadius: BorderRadius.circular(size * 0.32),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Icon(icon, color: color, size: size * 0.54),
      );
}

/// The signature shield: a ring that fills when protection is on, with a soft glow that breathes slowly.
/// Holds still when the phone asks for reduced motion.
class ShieldRing extends StatefulWidget {
  const ShieldRing({super.key, required this.activeCount, required this.total, this.size = 132, this.level});
  final int activeCount, total;
  final double size;

  /// Overrides the colour ('safe' | 'warning' | 'danger'); by default it follows how many shields are on.
  final String? level;
  @override
  State<ShieldRing> createState() => _ShieldRingState();
}

class _ShieldRingState extends State<ShieldRing> with SingleTickerProviderStateMixin {
  late final AnimationController pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      pulse.stop();
      pulse.value = 0.5;
    } else if (!pulse.isAnimating) {
      pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.activeCount > 0;
    final lv = widget.level ?? (widget.activeCount == widget.total ? 'safe' : 'warning');
    final c = on || widget.level != null ? SL.fg(context, lv) : Theme.of(context).colorScheme.onSurface.withAlpha(90);
    final size = widget.size;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: widget.total == 0 ? 0 : widget.activeCount / widget.total),
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => AnimatedBuilder(
          animation: pulse,
          builder: (context, _) => CustomPaint(
            painter: _RingPainter(v, c, Colors.white.withAlpha(18), on || widget.level != null ? pulse.value : 0),
            child: Center(
              child: Icon(on || widget.level != null ? Icons.shield_rounded : Icons.shield_outlined, size: size * 0.40, color: c),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.color, this.track, this.glow);
  final double v, glow;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size s) {
    final center = s.center(Offset.zero);
    final stroke = s.width * 0.075;
    // Soft glow behind the shield.
    if (glow > 0 || v > 0) {
      canvas.drawCircle(
        center,
        s.width * (0.30 + 0.04 * glow),
        Paint()
          ..color = color.withAlpha((40 + 50 * glow).round())
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.width * 0.16),
      );
    }
    final r = Rect.fromCircle(center: center, radius: s.width / 2 - stroke);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    if (v > 0) {
      canvas.drawArc(
        r,
        -math.pi / 2,
        math.pi * 2 * v,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.8
          ..strokeCap = StrokeCap.round
          ..color = color.withAlpha((40 + 40 * glow).round())
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke),
      );
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * v, false, p..color = color);
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.v != v || o.color != color || o.glow != glow;
}

/// A protection switch row with icon, title, explanation and an ON/OFF switch.
class ShieldSwitch extends StatelessWidget {
  const ShieldSwitch({super.key, required this.icon, required this.title, required this.subtitle, required this.value, required this.onChanged, this.footer});
  final IconData icon;
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconTile(icon, color: value ? SL.fg(context, 'safe') : cs.onSurface.withAlpha(140)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                const SizedBox(width: 8),
                Text(value ? tr('ON') : tr('OFF'),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1, color: value ? SL.fg(context, 'safe') : cs.onSurface.withAlpha(120))),
              ]),
              const SizedBox(height: 4),
              Text(subtitle, style: TextStyle(color: cs.onSurface.withAlpha(170), fontSize: 14, height: 1.4)),
            ]),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ]),
        if (footer != null) ...[const SizedBox(height: 12), footer!],
      ]),
    );
  }
}

/// A "Learn more" link that reveals extra detail in place.
class LearnMore extends StatefulWidget {
  const LearnMore({super.key, required this.child, this.label, this.initiallyOpen = false});
  final Widget child;
  final String? label;
  final bool initiallyOpen;
  @override
  State<LearnMore> createState() => _LearnMoreState();
}

class _LearnMoreState extends State<LearnMore> {
  late bool open = widget.initiallyOpen;
  @override
  Widget build(BuildContext context) {
    final noMotion = MediaQuery.of(context).disableAnimations;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => open = !open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(open ? tr('Show less') : (widget.label ?? tr('Learn more')),
                style: const TextStyle(color: SL.accent, fontWeight: FontWeight.w700, fontSize: 14)),
            Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: SL.accent, size: 20),
          ]),
        ),
      ),
      AnimatedSize(
        duration: Duration(milliseconds: noMotion ? 0 : 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: open ? Padding(padding: const EdgeInsets.only(top: 4), child: widget.child) : const SizedBox.shrink(),
      ),
    ]);
  }
}

String timeAgo(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return tr('just now');
  if (d.inMinutes < 60) return tr('{n} min ago', {'n': d.inMinutes});
  if (d.inHours < 24) return tr('{n} h ago', {'n': d.inHours});
  return tr('{n} d ago', {'n': d.inDays});
}
