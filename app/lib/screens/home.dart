import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import 'document_check.dart';
import 'panic.dart';
import 'payment_check.dart';
import 'shield_health.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onCheck, required this.onAlerts});
  final VoidCallback onCheck, onAlerts;
  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Map<String, dynamic> s = {};
  Map<String, dynamic> sec = {};
  Map<String, dynamic>? health;
  bool captured = false;
  List<Map<String, dynamic>> alerts = [];
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.instance.onScreenCaptured = (c) => mounted ? setState(() => captured = c) : null;
    alertsVersion.addListener(refresh);
    refresh();
  }

  @override
  void dispose() {
    alertsVersion.removeListener(refresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from system settings or a permission screen: re-read the real state.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    final st = await Native.instance.status();
    final h = await Native.instance.history();
    final sc = await Native.instance.securityStatus();
    final hh = await Native.instance.shieldHealth();
    if (!mounted) return;
    setState(() {
      s = st;
      sec = sc;
      health = hh;
      captured = st['screenCaptured'] == true;
      alerts = h;
    });
  }

  bool get ios => s['platform'] == 'ios';
  bool get web => Native.instance.isWeb || s['platform'] == 'web';

  Future<void> _toggle(Future<Map<String, dynamic>> Function() f) async {
    setState(() => busy = true);
    final st = await f();
    if (!mounted) return;
    setState(() {
      s = st;
      busy = false;
    });
    final hh = await Native.instance.shieldHealth();
    if (mounted) setState(() => health = hh);
  }

  /// Prominent disclosure (Google Play policy): explain exactly what is read and why, before the system permission prompt.
  Future<void> _shield(String which, bool on) async {
    if (on) {
      final sms = which == 'sms';
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(sms ? tr('Turn on SMS Shield?') : tr('Turn on Call Shield?')),
          content: Text(sms
              ? (ios
                  ? tr('Second Look will check text messages from unknown senders and move likely scams to Junk. Checks happen on this iPhone. Messages are not uploaded, stored on a server or shared.')
                  : tr('Second Look will receive each new SMS (sender and text) while SMS Shield is on, to check it for scams and warn you. Checks happen on this phone. SMS are not uploaded, stored on a server or shared. Each checked SMS is listed in Alerts on this phone with a short preview (codes hidden). Your phone will ask you to allow SMS access next. You can turn this off at any time.'))
              : (ios
                  ? tr('Second Look will give iPhone a list of numbers that you or many Second Look users reported, so it can label or block them. The list stays on this iPhone.')
                  : tr('Second Look will see the number of each incoming call from someone not in your contacts, to tell you who may be calling and warn about scams. It never records calls or reads your contacts or call log, and numbers are not uploaded. Your phone will ask you to choose Second Look as your caller ID & spam app next. You can turn this off at any time.'))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Not now'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Agree and continue'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _toggle(() => which == 'sms' ? Native.instance.setSmsShield(on) : Native.instance.setCallShield(on));
  }

  void _open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  Future<void> _openHealth() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShieldHealthScreen()));
    if (mounted) refresh();
  }

  static int _ms(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  /// "12 messages and 3 calls checked today", from this phone's alert list.
  String _todayLine() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final today = alerts.where((a) => _ms(a['at']) >= start).toList();
    final m = today.where((a) => a['kind'] == 'sms').length;
    final c = today.where((a) => a['kind'] == 'call').length;
    final ms = m == 1 ? tr('1 message') : tr('{n} messages', {'n': m});
    final cs = c == 1 ? tr('1 call') : tr('{n} calls', {'n': c});
    return tr('{messages} and {calls} checked today', {'messages': ms, 'calls': cs});
  }

  @override
  Widget build(BuildContext context) {
    final sms = s['smsShield'] == true, call = s['callShield'] == true;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: refresh,
          child: ListView(padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 24), children: [
            // ---- header: logo + name, language pill
            Row(children: [
              const Icon(Icons.shield_outlined, color: SL.accent, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text('Second Look', maxLines: 1, overflow: TextOverflow.ellipsis, style: SL.h(18, spacing: 0.36))),
              const LanguageButton(),
            ]),
            if (captured)
              _Warn(
                icon: Icons.cast_connected_rounded,
                title: tr('Your screen is being shared or recorded'),
                text: tr('If someone on a call asked you to share your screen, stop now. Scammers use it to read your OTPs.'),
              ),
            if (sec['signatureOk'] == false || sec['rulesIntact'] == false)
              _Warn(
                icon: Icons.gpp_bad_rounded,
                title: tr('This copy of Second Look was modified'),
                text: tr('Delete it and install Second Look again from the official store.'),
              )
            else if (sec['hooking'] == true || sec['debugger'] == true)
              _Warn(
                icon: Icons.bug_report_rounded,
                title: tr('A hacking tool is attached to this app'),
                text: tr('Something is trying to read or change Second Look while it runs. Restart your phone, and don\'t do banking until it\'s gone.'),
              )
            else if (sec['rooted'] == true)
              _Warn(
                icon: Icons.warning_amber_rounded,
                title: ios ? tr('This iPhone is jailbroken') : tr('This phone is rooted'),
                text: tr('Apps on it can bypass normal security. Be extra careful with banking and OTPs.'),
              ),
            // ---- the status orb
            const SizedBox(height: 24),
            _status(context, sms, call),
            // ---- the one big action
            const SizedBox(height: 18),
            GlowButton(label: tr('Check anything'), icon: Icons.qr_code_scanner_rounded, onPressed: widget.onCheck),
            const SizedBox(height: 8),
            Text(tr('Paste a link, SMS, number or UPI · or take a photo'), textAlign: TextAlign.center, style: const TextStyle(color: SL.textMuted, fontSize: 13)),
            // ---- four quick tools
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: _Tile(icon: Icons.chat_bubble_outline_rounded, label: tr('SMS'), onTap: widget.onCheck)),
              const SizedBox(width: 10),
              Expanded(child: _Tile(icon: Icons.phone_outlined, label: tr('Number'), onTap: widget.onCheck)),
              const SizedBox(width: 10),
              Expanded(child: _Tile(icon: Icons.credit_card_rounded, label: tr('Payment'), onTap: () => _open(const PaymentCheckScreen()))),
              const SizedBox(width: 10),
              Expanded(child: _Tile(icon: Icons.description_outlined, label: tr('Document'), onTap: () => _open(const DocumentCheckScreen()))),
            ]),
            // ---- help now
            const SizedBox(height: 12),
            _PanicButton(onTap: () => _open(const PanicScreen())),
          ]),
        ),
      ),
    );
  }

  /// The radar orb, one clear headline and the two shield pills. Colour follows the real state:
  /// green = protected, amber = something to fix or a shield off, red = a shield is on but broken.
  Widget _status(BuildContext context, bool sms, bool call) {
    String title;
    String sub;
    String level;
    VoidCallback? onTap;
    if (web) {
      title = tr('Check anything before you click');
      sub = tr('Nothing you paste is uploaded');
      level = 'safe';
    } else {
      final active = (sms ? 1 : 0) + (call ? 1 : 0);
      final broken = shieldBroken(health);
      var issues = healthIssues(health);
      if (issues == 0 && (s['smsNeedsPermission'] == true || s['callNeedsRole'] == true)) issues = 1;
      final android = !ios;
      if (broken != null) {
        title = broken == 'sms' ? tr('SMS Shield is on but isn\'t working yet') : tr('Call Shield is on but isn\'t working yet');
        sub = tr('Tap to fix');
        level = 'danger';
        onTap = _openHealth;
      } else if (active == 0) {
        title = tr('Shields are off');
        sub = tr('Turn on a shield below.');
        level = 'warning';
      } else if (issues > 0 && android) {
        title = issues == 1 ? tr('1 thing to fix') : tr('{n} things to fix', {'n': issues});
        sub = tr('Tap to open Protection check');
        level = 'warning';
        onTap = _openHealth;
      } else if (active == 1) {
        title = tr('One shield is on');
        sub = tr('Turn on both for full protection.');
        level = 'warning';
      } else {
        title = tr('You\'re protected');
        sub = _todayLine();
        level = 'safe';
      }
    }
    final head = Column(children: [
      _StatusOrb(level: level),
      const SizedBox(height: 10),
      Text(title, textAlign: TextAlign.center, style: SL.h(30, height: 1.15, spacing: -0.3)),
      const SizedBox(height: 4),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Flexible(
          child: Text(sub,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: onTap != null ? SL.pale(level) : SL.textSecondary, fontWeight: onTap != null ? FontWeight.w700 : FontWeight.w500)),
        ),
        if (onTap != null) Icon(Icons.chevron_right_rounded, size: 20, color: SL.pale(level)),
      ]),
    ]);
    return Column(children: [
      if (onTap == null)
        head
      else
        Semantics(
          button: true,
          child: InkWell(borderRadius: BorderRadius.circular(24), onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: head)),
        ),
      if (!web) ...[
        const SizedBox(height: 14),
        Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 8, children: [
          _ShieldPill(
            on: sms,
            label: sms ? tr('SMS shield on') : tr('SMS shield off'),
            onTap: busy ? null : () => _shield('sms', !sms),
          ),
          _ShieldPill(
            on: call,
            label: call ? tr('Call shield on') : tr('Call shield off'),
            onTap: busy ? null : () => _shield('call', !call),
          ),
        ]),
        if (ios && sms) _IosStep(text: tr('Also switch it on in iPhone Settings › Apps › Messages › Unknown & Spam › Second Look.'), which: 'sms_filter'),
        if (ios && call) _IosStep(text: tr('Also switch it on in iPhone Settings › Apps › Phone › Call Blocking & Identification.'), which: 'call_directory'),
      ],
    ]);
  }
}

/// 236 px status orb: a thin outer ring, a dashed inner ring, a rotating radar sweep (4 s), a breathing glow (3 s)
/// and a 112 px centre with the shield in the status colour. Holds still when the phone asks for reduced motion.
class _StatusOrb extends StatefulWidget {
  const _StatusOrb({required this.level});
  final String level;
  @override
  State<_StatusOrb> createState() => _StatusOrbState();
}

class _StatusOrbState extends State<_StatusOrb> with TickerProviderStateMixin {
  late final AnimationController sweep = AnimationController(vsync: this, duration: const Duration(seconds: 4));
  late final AnimationController pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      sweep.stop();
      pulse.stop();
      sweep.value = 0.0;
      pulse.value = 1.0;
    } else {
      if (!sweep.isAnimating) sweep.repeat();
      if (!pulse.isAnimating) pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    sweep.dispose();
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SL.fgOf(widget.level);
    return ExcludeSemantics(
      child: SizedBox(
        width: 236,
        height: 236,
        child: Stack(alignment: Alignment.center, children: [
          Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _OrbPainter(c, sweep, pulse)))),
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              color: SL.deep(widget.level),
              shape: BoxShape.circle,
              border: Border.all(color: c, width: 2),
              boxShadow: [BoxShadow(color: c.withAlpha(115), blurRadius: 40)],
            ),
            child: Icon(SL.icon(widget.level), size: 54, color: c),
          ),
        ]),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.color, this.sweep, this.pulse) : super(repaint: Listenable.merge([sweep, pulse]));
  final Color color;
  final Animation<double> sweep, pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    // Outer thin ring.
    canvas.drawCircle(c, r - 0.5, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withAlpha(56));

    // Dashed inner ring (inset 22).
    final dr = r - 22.5;
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withAlpha(89);
    final n = (2 * math.pi * dr / 7).floor();
    final step = 2 * math.pi / n;
    final rect = Rect.fromCircle(center: c, radius: dr);
    for (var i = 0; i < n; i++) {
      canvas.drawArc(rect, i * step, step * 0.5, false, dash);
    }

    // Radar sweep: a 60° wedge that fades in to a sharp leading edge, turning once every 4 s.
    final full = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: [color.withAlpha(0), color.withAlpha(89), color.withAlpha(0), color.withAlpha(0)],
          stops: const [0.0, 60 / 360, 61 / 360, 1.0],
          transform: GradientRotation(-math.pi / 2 + sweep.value * 2 * math.pi),
        ).createShader(full),
    );

    // Breathing glow (inset 48): opacity .55 → 1, scale 1 → 1.04.
    final p = Curves.easeInOut.transform(pulse.value.clamp(0.0, 1.0).toDouble());
    final op = 0.55 + 0.45 * p;
    final gr = (r - 48) * (1 + 0.04 * p);
    final g = Rect.fromCircle(center: c, radius: gr);
    canvas.drawCircle(
      c,
      gr,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withAlpha((82 * op).round()), color.withAlpha((10 * op).round()), color.withAlpha((10 * op).round())],
          stops: const [0.0, 0.7, 1.0],
        ).createShader(g),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter o) => o.color != color || o.sweep != sweep || o.pulse != pulse;
}

/// "SMS shield on" — a pill with a status dot; tapping it switches the shield.
class _ShieldPill extends StatelessWidget {
  const _ShieldPill({required this.on, required this.label, required this.onTap});
  final bool on;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final c = on ? SL.safeD : SL.textMuted;
    final r = BorderRadius.circular(20);
    return Semantics(
      toggled: on,
      button: true,
      child: Material(
        color: on ? SL.safeD.withAlpha(26) : const Color(0x0AFFFFFF),
        shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: on ? SL.safeD.withAlpha(102) : const Color(0x338CDCFF))),
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: on ? SL.safeLight : SL.textSecondary)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One of the four 88 px tool tiles under the main button.
class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(18);
    return Material(
      color: SL.glass,
      shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: SL.glassBorder)),
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        child: SizedBox(
          height: 88,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 26, color: SL.accent),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: SL.text)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// "Being scammed right now? Get help" — red outline button to the panic steps.
class _PanicButton extends StatelessWidget {
  const _PanicButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(16);
    return Material(
      color: SL.dangerD.withAlpha(26),
      shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: SL.dangerD.withAlpha(115))),
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.warning_amber_rounded, size: 20, color: SL.dangerD),
            const SizedBox(width: 10),
            Flexible(
              child: Text(tr('Being scammed right now? Get help'),
                  textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: SL.dangerLight)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Warn extends StatelessWidget {
  const _Warn({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Panel(
          radius: 20,
          padding: const EdgeInsets.all(14),
          color: SL.dangerD.withAlpha(18),
          borderColor: SL.dangerD.withAlpha(102),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconTile(icon, color: SL.dangerD, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5, color: SL.dangerLight)),
                const SizedBox(height: 3),
                Text(text, style: const TextStyle(fontSize: 13.5, height: 1.4, color: SL.textSoft)),
              ]),
            ),
          ]),
        ),
      );
}

class _IosStep extends StatelessWidget {
  const _IosStep({required this.text, required this.which});
  final String text, which;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 0, 0),
        child: Row(children: [
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(150)))),
          TextButton(onPressed: () => Native.instance.openSystemSettings(which), child: Text(tr('Open Settings'))),
        ]),
      );
}
