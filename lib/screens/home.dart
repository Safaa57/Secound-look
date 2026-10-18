import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../community.dart';
import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import 'document_check.dart';
import 'panic.dart';
import 'payment_check.dart';
import 'result.dart';
import 'shield_health.dart';
import 'upi_check.dart';

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
  bool checking = false;
  final paste = TextEditingController();

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
    paste.dispose();
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

  Future<void> _pasteFromClipboard() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text;
    if (!mounted || t == null || t.trim().isEmpty) return;
    setState(() => paste.text = t);
  }

  /// Checks whatever was pasted. The engine works out whether it's a link, a message, a phone number or a UPI ID.
  Future<void> _check() async {
    final t = paste.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (t.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Paste a link, message, number or UPI ID first.'))));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => checking = true);
    Map<String, dynamic>? r;
    try {
      final first = await Native.instance.analyze(t);
      final st = await Native.instance.status(); // the community setting may have changed in Settings
      r = await Community.enrich(first, st);
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message ?? tr('The check failed'))));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(tr('The check failed'))));
    }
    if (!mounted) return;
    setState(() => checking = false);
    final res = r;
    if (res == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(result: res, title: 'Check result')));
    if (mounted) refresh();
  }

  @override
  Widget build(BuildContext context) {
    final sms = s['smsShield'] == true, call = s['callShield'] == true;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 28), children: [
            // ---- top bar: name + language switch
            Row(children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [SL.accent, SL.accentDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: SL.accent.withAlpha(70), blurRadius: 16)],
                ),
                child: const Icon(Icons.shield_rounded, color: SL.onAccent, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('Second Look', style: Theme.of(context).textTheme.titleLarge)),
              const LanguageButton(),
            ]),
            if (captured) ...[
              const SizedBox(height: 14),
              _Warn(
                icon: Icons.cast_connected_rounded,
                title: tr('Your screen is being shared or recorded'),
                text: tr('If someone on a call asked you to share your screen, stop now. Scammers use it to read your OTPs.'),
              ),
            ],
            if (sec['signatureOk'] == false || sec['rulesIntact'] == false) ...[
              const SizedBox(height: 14),
              _Warn(
                icon: Icons.gpp_bad_rounded,
                title: tr('This copy of Second Look was modified'),
                text: tr('Delete it and install Second Look again from the official store.'),
              ),
            ] else if (sec['hooking'] == true || sec['debugger'] == true) ...[
              const SizedBox(height: 14),
              _Warn(
                icon: Icons.bug_report_rounded,
                title: tr('A hacking tool is attached to this app'),
                text: tr('Something is trying to read or change Second Look while it runs. Restart your phone, and don\'t do banking until it\'s gone.'),
              ),
            ] else if (sec['rooted'] == true) ...[
              const SizedBox(height: 14),
              _Warn(
                icon: Icons.warning_amber_rounded,
                title: ios ? tr('This iPhone is jailbroken') : tr('This phone is rooted'),
                text: tr('Apps on it can bypass normal security. Be extra careful with banking and OTPs.'),
              ),
            ],
            const SizedBox(height: 16),
            // ---- hero status
            if (web) _webHero(context) else _hero(context, sms, call),
            const SizedBox(height: 14),
            // ---- paste & check
            Panel(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Icon(Icons.content_paste_search_rounded, color: SL.accent, size: 22),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr('Paste & check'), style: Theme.of(context).textTheme.titleMedium)),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: paste,
                  minLines: 1,
                  maxLines: 4,
                  inputFormatters: [LengthLimitingTextInputFormatter(10000)],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _check(),
                  decoration: InputDecoration(
                    hintText: tr('Link, SMS, phone number or UPI ID'),
                    suffixIcon: IconButton(tooltip: tr('Paste'), onPressed: _pasteFromClipboard, icon: const Icon(Icons.content_paste_rounded)),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: checking ? null : _check,
                  icon: checking
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.shield_rounded),
                  label: Text(checking ? tr('Checking…') : tr('Check it')),
                ),
              ]),
            ),
            // ---- tools
            SectionLabel(tr('Tools'), icon: Icons.grid_view_rounded),
            GridView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              // A fixed row height keeps two-line labels from overflowing on narrow phones.
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 120),
              children: [
                _Tool(icon: Icons.sms_rounded, title: tr('Message or link'), onTap: widget.onCheck),
                _Tool(icon: Icons.phone_in_talk_rounded, title: tr('Phone number'), onTap: widget.onCheck),
                _Tool(icon: Icons.receipt_long_rounded, title: tr('Payment proof'), onTap: () => _open(const PaymentCheckScreen())),
                _Tool(icon: Icons.qr_code_scanner_rounded, title: tr('UPI or QR'), onTap: () => _open(const UpiCheckScreen())),
                _Tool(icon: Icons.badge_rounded, title: tr('Document'), onTap: () => _open(const DocumentCheckScreen())),
                _Tool(icon: Icons.sos_rounded, title: tr('Being scammed?'), danger: true, onTap: () => _open(const PanicScreen())),
              ],
            ),
            // ---- recent alerts
            SectionLabel(
              tr('Recent alerts'),
              icon: Icons.notifications_rounded,
              trailing: alerts.isEmpty ? null : TextButton(onPressed: widget.onAlerts, child: Text(tr('See all'))),
            ),
            if (alerts.isEmpty)
              Panel(
                child: Row(children: [
                  Icon(Icons.inbox_rounded, color: cs.onSurface.withAlpha(140)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      ios || web ? tr('Your checks will show up here.') : tr('Nothing checked yet. New SMS and calls show up here.'),
                      style: TextStyle(color: cs.onSurface.withAlpha(170)),
                    ),
                  ),
                ]),
              )
            else
              for (final a in alerts.take(3)) ...[AlertTile(a: a), const SizedBox(height: 8)],
            // ---- one safety tip
            SectionLabel(tr('Safety tip'), icon: Icons.lightbulb_rounded),
            const _TipCard(),
          ]),
        ),
      ),
    );
  }

  Widget _webHero(BuildContext context) => Panel(
        padding: const EdgeInsets.all(20),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [SL.accent.withAlpha(40), Colors.white.withAlpha(8)]),
        borderColor: SL.accent.withAlpha(70),
        child: Row(children: [
          const ShieldRing(activeCount: 1, total: 1, size: 88, level: 'safe'),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Check anything before you click'), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(tr('Nothing you paste is uploaded'), style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(170))),
            ]),
          ),
        ]),
      );

  /// The status card: a glowing shield, one clear headline, and the two shield switches.
  Widget _hero(BuildContext context, bool sms, bool call) {
    final active = (sms ? 1 : 0) + (call ? 1 : 0);
    final caught = alerts.where((a) => a['level'] != null && a['level'] != 'safe').length;
    final broken = shieldBroken(health);
    var issues = healthIssues(health);
    if (issues == 0 && (s['smsNeedsPermission'] == true || s['callNeedsRole'] == true)) issues = 1;
    final android = !ios;

    String title;
    String sub;
    String? level; // null = grey (shields off)
    VoidCallback? onTap;
    if (broken != null) {
      title = broken == 'sms' ? tr('SMS Shield is on but isn\'t working yet') : tr('Call Shield is on but isn\'t working yet');
      sub = tr('Tap to fix');
      level = broken == 'sms' || health?['restrictedSettingsLikely'] == true ? 'danger' : 'warning';
      onTap = _openHealth;
    } else if (active == 0) {
      title = tr('Shields are off');
      sub = tr('Turn on a shield below.');
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
      sub = caught > 0 ? tr('{n} threats caught', {'n': caught}) : tr('New SMS and calls are checked');
      level = 'safe';
    }
    final tint = level == null ? Colors.white.withAlpha(26) : SL.fg(context, level).withAlpha(44);
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(170);

    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [tint, Colors.white.withAlpha(6)]),
      borderColor: level == null ? null : SL.fg(context, level).withAlpha(80),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Row(children: [
            ShieldRing(activeCount: active, total: 2, size: 96, level: level),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Row(children: [
                  Flexible(child: Text(sub, style: TextStyle(color: onTap != null ? SL.fg(context, level ?? 'warning') : muted, fontWeight: FontWeight.w600))),
                  if (onTap != null) Icon(Icons.chevron_right_rounded, size: 20, color: SL.fg(context, level ?? 'warning')),
                ]),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        _ShieldRow(
          icon: Icons.sms_rounded,
          title: tr('SMS Shield'),
          sub: ios ? tr('Filters unknown senders') : tr('Checks new SMS'),
          value: sms,
          onChanged: busy ? null : (v) => _shield('sms', v),
        ),
        if (ios && sms) _IosStep(text: tr('Also switch it on in iPhone Settings › Apps › Messages › Unknown & Spam › Second Look.'), which: 'sms_filter'),
        const SizedBox(height: 8),
        _ShieldRow(
          icon: Icons.ring_volume_rounded,
          title: tr('Call Shield'),
          sub: ios ? tr('Labels reported numbers') : tr('Screens unknown callers'),
          value: call,
          onChanged: busy ? null : (v) => _shield('call', v),
        ),
        if (ios && call) _IosStep(text: tr('Also switch it on in iPhone Settings › Apps › Phone › Call Blocking & Identification.'), which: 'call_directory'),
        if (android)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _openHealth,
              icon: Icon(Icons.health_and_safety_rounded, size: 19, color: issues > 0 ? SL.fg(context, 'warning') : SL.accent),
              label: Text(tr('Protection check')),
            ),
          )
        else
          const SizedBox(height: 4),
      ]),
    );
  }
}

/// One shield as a pill-shaped row with its switch.
class _ShieldRow extends StatelessWidget {
  const _ShieldRow({required this.icon, required this.title, required this.sub, required this.value, required this.onChanged});
  final IconData icon;
  final String title, sub;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) {
    final on = SL.fg(context, 'safe');
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(150);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: value ? on.withAlpha(22) : Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: value ? on.withAlpha(90) : Colors.white.withAlpha(24)),
      ),
      child: Row(children: [
        Icon(icon, size: 22, color: value ? on : muted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            Text('${value ? tr('ON') : tr('OFF')} · $sub',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: value ? on : muted)),
          ]),
        ),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }
}

/// A compact tool button in the 3×2 grid.
class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.title, required this.onTap, this.danger = false});
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final c = danger ? SL.fg(context, 'danger') : SL.accent;
    return Panel(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      color: danger ? SL.bg(context, 'danger') : null,
      borderColor: danger ? c.withAlpha(90) : null,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconTile(icon, color: c, size: 44),
        const SizedBox(height: 8),
        Text(title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, height: 1.2, color: danger ? c : null)),
      ]),
    );
  }
}

/// One short, practical safety rule; a different one each day, with a button for the next.
class _TipCard extends StatefulWidget {
  const _TipCard();
  @override
  State<_TipCard> createState() => _TipCardState();
}

class _TipCardState extends State<_TipCard> {
  static const tips = [
    'No bank, police officer or company will ever ask for your OTP, UPI PIN or CVV.',
    'You never enter a UPI PIN or scan a QR code to receive money.',
    'There is no such thing as a "digital arrest". Police don\'t hold people on video calls.',
    'Never install an app (APK) or screen-sharing app because a caller asked you to.',
    'A payment screenshot isn\'t proof. Check the money in your own bank app first.',
    'Never dial a code like *401* that someone sends you. It can forward your calls to a scammer.',
    '"Urgent" and "within 2 hours" are there to stop you from checking. Slow down.',
    'Call back on the number printed on your card or bill, not the one in the message.',
    'Earning money for liking videos or rating hotels is a scam. It always ends with you paying.',
    'If you lose money, call 1930 immediately. Quick reports can freeze the stolen money.',
  ];
  late int i = DateTime.now().difference(DateTime(2026)).inDays.abs() % tips.length;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        color: SL.amber.withAlpha(18),
        borderColor: SL.amber.withAlpha(60),
        child: Row(children: [
          const Icon(Icons.lightbulb_rounded, color: SL.amber, size: 26),
          const SizedBox(width: 12),
          Expanded(child: Text(tr(tips[i]), style: const TextStyle(fontSize: 14.5, height: 1.4, fontWeight: FontWeight.w600))),
          IconButton(
            tooltip: tr('Next tip'),
            onPressed: () => setState(() => i = (i + 1) % tips.length),
            icon: const Icon(Icons.arrow_forward_rounded, color: SL.amber),
          ),
        ]),
      );
}

class _Warn extends StatelessWidget {
  const _Warn({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Panel(
        color: SL.bg(context, 'danger'),
        borderColor: SL.fg(context, 'danger').withAlpha(110),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: SL.fg(context, 'danger')),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: SL.fg(context, 'danger'))),
              const SizedBox(height: 3),
              Text(text, style: const TextStyle(fontSize: 14, height: 1.4)),
            ]),
          ),
        ]),
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
