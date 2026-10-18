import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme.dart';

/// Glass card used for every surface in the app: white @4% with a 1px cool-cyan hairline.
/// (No blur: it would be costly inside long scrolling lists.)
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color, this.borderColor, this.onTap, this.gradient, this.radius});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final Gradient? gradient;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius ?? SL.radius);
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

/// The flat navy ground behind a screen.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(decoration: SL.backdrop, child: child);
}

/// Small spaced capitals in Sora ("WHY", "TOOLS").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.icon, this.trailing});
  final String text;
  final IconData? icon; // kept for old call sites; the new design shows no icon
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(2, 24, 2, trailing == null ? 10 : 4),
        child: Row(children: [
          Expanded(child: Text(text.toUpperCase(), style: SL.h(15, color: SL.textSecondary, weight: FontWeight.w600, spacing: 0.6))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Small coloured pill for verdicts, risk and report counts.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, required this.fg, required this.bg, this.icon, this.textColor});
  final String text;
  final Color fg, bg;
  final IconData? icon;
  final Color? textColor;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: fg.withAlpha(102))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 5)],
          Flexible(child: Text(text, style: TextStyle(color: textColor ?? fg, fontWeight: FontWeight.w700, fontSize: 13))),
        ]),
      );
}

/// A round tinted icon (list rows, settings sections, reasons).
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, required this.color, this.size = 44});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color.withAlpha(41), shape: BoxShape.circle),
        child: Icon(icon, color: color, size: size * 0.5),
      );
}

/// The big primary button: a solid fill, a Sora label and a soft glow in the same colour.
class GlowButton extends StatelessWidget {
  const GlowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = SL.accent,
    this.textColor = SL.onAccent,
    this.height = 64,
    this.radius = 20,
    this.fontSize = 18,
    this.glow = true,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color, textColor;
  final double height, radius, fontSize;
  final bool glow, busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final r = BorderRadius.circular(radius);
    return Semantics(
      button: true,
      enabled: enabled,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: glow && enabled ? [BoxShadow(color: color.withAlpha(89), blurRadius: 40, offset: const Offset(0, 10))] : null,
        ),
        child: Material(
          color: enabled || busy ? color : color.withAlpha(90),
          borderRadius: r,
          child: InkWell(
            borderRadius: r,
            onTap: enabled ? onPressed : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (busy)
                  SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: textColor))
                else if (icon != null)
                  Icon(icon, size: 24, color: textColor),
                if (busy || icon != null) const SizedBox(width: 12),
                Flexible(
                  child: Text(label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: SL.h(fontSize, color: textColor, height: 1.15)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet outlined button (white @5%, light border) used beside the primary one.
class SoftButton extends StatelessWidget {
  const SoftButton({super.key, required this.label, required this.onPressed, this.icon, this.height = 54, this.radius = 16, this.color, this.fill, this.border, this.fontSize = 15});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height, radius, fontSize;
  final Color? color, fill, border;
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final c = color ?? SL.text;
    return SizedBox(
      height: height,
      child: Material(
        color: fill ?? const Color(0x0DFFFFFF),
        shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: border ?? const Color(0x33FFFFFF))),
        child: InkWell(
          borderRadius: r,
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[Icon(icon, size: 19, color: c), const SizedBox(width: 8)],
              Flexible(
                child: Text(label,
                    maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, fontSize: fontSize, height: 1.2, color: c)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The 44 px round back button at the top of a screen.
class BackCircle extends StatelessWidget {
  const BackCircle({super.key, this.onPressed, this.border = const Color(0x2E8CDCFF)});
  final VoidCallback? onPressed;
  final Color border;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: MaterialLocalizations.of(context).backButtonTooltip,
        child: Material(
          color: Colors.transparent,
          shape: CircleBorder(side: BorderSide(color: border)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed ?? () => Navigator.of(context).maybePop(),
            child: const SizedBox(width: 44, height: 44, child: Icon(Icons.chevron_left_rounded, size: 26, color: SL.text)),
          ),
        ),
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
