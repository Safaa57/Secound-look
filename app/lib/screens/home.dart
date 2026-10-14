import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'panic.dart';
import 'payment_check.dart';
import 'result.dart';
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
  bool captured = false;
  List<Map<String, dynamic>> alerts = [];
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.instance.onScreenCaptured = (c) => mounted ? setState(() => captured = c) : null;
    refresh();
  }

  @override
  void dispose() {
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
    if (!mounted) return;
    setState(() {
      s = st;
      sec = sc;
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
                  : tr('Second Look will receive each new SMS (sender and text) while SMS Shield is on, to check it for scams and warn you. Checks happen on this phone. SMS are not uploaded, stored on a server or shared. Only SMS that look like scams are kept in Alerts on this phone. Your phone will ask you to allow SMS access next. You can turn this off at any time.'))
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

  @override
  Widget build(BuildContext context) {
    final sms = s['smsShield'] == true, call = s['callShield'] == true;
    final active = (sms ? 1 : 0) + (call ? 1 : 0);
    final cs = Theme.of(context).colorScheme;
    final caught = alerts.where((a) => a['level'] != 'safe').length;
    final headline = active == 2 ? tr('Both shields are on') : active == 1 ? tr('One shield is on') : tr('Shields are off');

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 32), children: [
            // ---- top bar: name + language switch
            Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: SL.cobalt, borderRadius: BorderRadius.circular(11)),
                child: const Icon(Icons.shield_rounded, color: Colors.white, size: 21),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('Second Look', style: Theme.of(context).textTheme.titleLarge)),
              const LanguageButton(),
            ]),
            const SizedBox(height: 12),
            // ---- trust strip
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Trust(Icons.phone_android_rounded, web ? tr('Checks in your browser') : tr('Checks on this phone')),
              if (!web) _Trust(Icons.lock_rounded, tr('Encrypted')),
              _Trust(Icons.contacts_rounded, tr('Contacts never read')),
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
            // ---- hero
            if (web)
              Panel(
                padding: const EdgeInsets.all(22),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.laptop_chromebook_rounded, size: 40, color: cs.primary),
                  const SizedBox(height: 12),
                  Text(tr('Check anything before you click'), style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 6),
                  Text(
                    tr('Paste a link, a message or a phone number. The check runs in this browser and nothing you paste is uploaded. For automatic SMS and Call Shield, install Second Look on your Android phone or iPhone.'),
                    style: TextStyle(color: cs.onSurface.withAlpha(170), height: 1.4),
                  ),
                ]),
              )
            else
              Panel(
                padding: const EdgeInsets.all(22),
                child: Row(children: [
                  ShieldRing(activeCount: active, total: 2, size: 104),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(headline, style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 6),
                      Text(
                        caught == 0
                            ? (active == 0 ? tr('Switch on a shield below to check new SMS or calls on this phone.') : tr('New SMS and calls are checked on this phone. Nothing is uploaded.'))
                            : tr('{n} threats caught so far. Everything stays on this phone.', {'n': caught}),
                        style: TextStyle(color: cs.onSurface.withAlpha(170), height: 1.4),
                      ),
                    ]),
                  ),
                ]),
              ),
            // ---- tools
            SectionLabel(tr('Check before you trust')),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.25,
              children: [
                _Action(icon: Icons.manage_search_rounded, title: tr('Message, link or number'), sub: tr('Paste it to check'), onTap: widget.onCheck),
                _Action(icon: Icons.receipt_long_rounded, title: tr('Payment screenshot'), sub: tr('Spot fake "paid" proofs'), onTap: () => _open(const PaymentCheckScreen())),
                _Action(icon: Icons.qr_code_scanner_rounded, title: tr('UPI ID or QR'), sub: tr('Check before you pay'), onTap: () => _open(const UpiCheckScreen())),
                _Action(icon: Icons.sos_rounded, title: tr('Being scammed?'), sub: tr('Steps to take now'), danger: true, onTap: () => _open(const PanicScreen())),
              ],
            ),
            if (!web) ...[
              SectionLabel(tr('Your shields')),
              ShieldSwitch(
                icon: Icons.sms_rounded,
                title: tr('SMS Shield'),
                subtitle: ios
                    ? tr('Moves scam texts from unknown senders into the Junk folder before you see them.')
                    : tr('Checks every new SMS for scam links and tricks the moment it arrives.'),
                value: sms,
                onChanged: busy ? null : (v) => _shield('sms', v),
                footer: ios ? _IosStep(text: tr('Also switch it on in iPhone Settings › Apps › Messages › Unknown & Spam › Second Look.'), which: 'sms_filter') : null,
              ),
              const SizedBox(height: 12),
              ShieldSwitch(
                icon: Icons.ring_volume_rounded,
                title: tr('Call Shield'),
                subtitle: ios
                    ? tr('Labels and blocks numbers that you or many Second Look users reported as scams.')
                    : tr('Tells you who\'s calling (a person, business, telemarketer, bot or scam) while it rings.'),
                value: call,
                onChanged: busy ? null : (v) => _shield('call', v),
                footer: ios
                    ? _IosStep(text: tr('Also switch it on in iPhone Settings › Apps › Phone › Call Blocking & Identification.'), which: 'call_directory')
                    : (call
                        ? Row(children: [
                            Expanded(child: Text(tr('Silence likely scam calls'), style: TextStyle(color: cs.onSurface.withAlpha(190), fontWeight: FontWeight.w600))),
                            Switch(value: s['autoSilence'] == true, onChanged: (v) => _toggle(() => Native.instance.setAutoSilence(v))),
                          ])
                        : null),
              ),
              if (s['smsNeedsPermission'] == true || s['callNeedsRole'] == true) ...[
                const SizedBox(height: 12),
                Panel(
                  color: SL.bg(context, 'warning'),
                  child: Text(
                    s['smsNeedsPermission'] == true
                        ? tr('SMS Shield needs permission to read new SMS. Turn it on again and tap "Allow".')
                        : tr('Call Shield needs to be chosen as your caller ID & spam app. Turn it on again and pick Second Look.'),
                    style: TextStyle(color: SL.fg(context, 'warning'), fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
            // ---- tip of the day
            SectionLabel(tr('Safety tip')),
            const _TipCard(),
            // ---- alerts
            SectionLabel(alerts.isEmpty ? tr('Recent alerts') : tr('Recent alerts ({n})', {'n': alerts.length})),
            if (alerts.isEmpty)
              Panel(
                child: Text(
                  ios || web
                      ? tr('Checks you run from the Check tab show up here.')
                      : tr('Nothing suspicious yet. When SMS or Call Shield catches something, it shows up here and as a notification.'),
                  style: TextStyle(color: cs.onSurface.withAlpha(170)),
                ),
              )
            else ...[
              for (final a in alerts.take(4)) ...[AlertTile(a: a), const SizedBox(height: 10)],
              TextButton(onPressed: widget.onAlerts, child: Text(tr('See all alerts'))),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Trust extends StatelessWidget {
  const _Trust(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = SL.fg(context, 'safe');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: SL.bg(context, 'safe'), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c)),
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
  late int i = DateTime.now().difference(DateTime(2026)).inDays % tips.length;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Panel(
      color: cs.primary.withAlpha(16),
      borderColor: cs.primary.withAlpha(50),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lightbulb_rounded, color: SL.amber, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(tips[i]), style: const TextStyle(fontSize: 15.5, height: 1.45, fontWeight: FontWeight.w600)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => setState(() => i = (i + 1) % tips.length), child: Text(tr('Next tip'))),
            ),
          ]),
        ),
      ]),
    );
  }
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
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(150)))),
        TextButton(onPressed: () => Native.instance.openSystemSettings(which), child: Text(tr('Open Settings'))),
      ]);
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.title, required this.sub, required this.onTap, this.danger = false});
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final c = danger ? SL.fg(context, 'danger') : Theme.of(context).colorScheme.primary;
    return Panel(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: c.withAlpha(28), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: c, size: 24),
        ),
        const Spacer(),
        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, height: 1.2)),
        const SizedBox(height: 2),
        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(150))),
      ]),
    );
  }
}

/// One alert in a list.
class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.a});
  final Map<String, dynamic> a;
  @override
  Widget build(BuildContext context) {
    final level = a['level'] as String? ?? 'safe';
    return Panel(
      padding: const EdgeInsets.all(14),
      onTap: () {
        final r = (a['result'] as Map?)?.cast<String, dynamic>();
        if (r != null) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(result: r, title: a['title'] as String? ?? 'Alert')));
      },
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: SL.bg(context, level), borderRadius: BorderRadius.circular(12)),
          child: Icon(a['kind'] == 'call' ? Icons.call_rounded : Icons.sms_rounded, color: SL.fg(context, level)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${a['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${a['summary'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(160))),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Pill(level == 'danger' ? tr('Scam') : level == 'warning' ? tr('Suspicious') : tr('OK'), fg: SL.fg(context, level), bg: SL.bg(context, level)),
          const SizedBox(height: 4),
          Text(timeAgo((a['at'] as num).toInt()), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withAlpha(130))),
        ]),
      ]),
    );
  }
}
