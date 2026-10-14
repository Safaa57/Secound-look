import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme.dart';

/// Bordered surface used for every card in the app.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color, this.borderColor, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor ?? (dark ? const Color(0xFF26304A) : const Color(0xFFDCE1EC))),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(color: Colors.transparent, child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: box));
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: Theme.of(context).colorScheme.onSurface.withAlpha(150))),
      );
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
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 5)],
          Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
      );
}

/// The signature "shield ring": a calm ring that fills when protection is on.
class ShieldRing extends StatelessWidget {
  const ShieldRing({super.key, required this.activeCount, required this.total, this.size = 132});
  final int activeCount, total;
  final double size;
  @override
  Widget build(BuildContext context) {
    final on = activeCount > 0;
    final c = on ? SL.fg(context, activeCount == total ? 'safe' : 'warning') : Theme.of(context).colorScheme.onSurface.withAlpha(90);
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: total == 0 ? 0 : activeCount / total),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => CustomPaint(
          painter: _RingPainter(v, c, Theme.of(context).colorScheme.onSurface.withAlpha(25)),
          child: Center(child: Icon(on ? Icons.shield_rounded : Icons.shield_outlined, size: size * 0.42, color: c)),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.color, this.track);
  final double v;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size s) {
    final r = Rect.fromLTWH(8, 8, s.width - 16, s.height - 16);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    if (v > 0) canvas.drawArc(r, -math.pi / 2, math.pi * 2 * v, false, p..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.v != v || o.color != color;
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
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: value ? SL.bg(context, 'safe') : cs.onSurface.withAlpha(18), borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: value ? SL.fg(context, 'safe') : cs.onSurface.withAlpha(140)),
          ),
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

String timeAgo(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return tr('just now');
  if (d.inMinutes < 60) return tr('{n} min ago', {'n': d.inMinutes});
  if (d.inHours < 24) return tr('{n} h ago', {'n': d.inHours});
  return tr('{n} d ago', {'n': d.inDays});
}
