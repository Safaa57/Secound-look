import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';

/// Android only: true when the health map has real checks (not iPhone, not the browser).
bool healthAvailable(Map<String, dynamic>? h) => h != null && h.containsKey('smsPermission');

/// A shield the user switched on can't actually work: 'sms', 'call', or null.
String? shieldBroken(Map<String, dynamic>? h) {
  if (!healthAvailable(h)) return null;
  final m = h!;
  bool t(String k) => m[k] == true;
  final notify = t('notificationsAllowed');
  if (t('smsWanted') && (!t('smsPermission') || m['smsReceiverEnabled'] == false || !notify)) return 'sms';
  if (t('callWanted') && (!t('callRoleHeld') || !notify)) return 'call';
  return null;
}

/// How many checks need attention (used for the warning dot on Home and in Settings).
int healthIssues(Map<String, dynamic>? h) => _checks(h).where((c) => !c.ok).length;

class _Item {
  const _Item(this.title, this.ok, this.fix, {this.why});
  final String title;
  final bool ok;
  final String fix; // openSettings target
  final String? why;
}

List<_Item> _checks(Map<String, dynamic>? h) {
  if (!healthAvailable(h)) return const [];
  final m = h!;
  bool t(String k) => m[k] == true;
  final sms = t('smsWanted'), call = t('callWanted');
  return [
    if (sms) _Item(tr('SMS Shield can read new SMS'), t('smsPermission'), 'sms', why: tr('Without this, new SMS can\'t be checked.')),
    if (sms && m.containsKey('smsReceiverEnabled'))
      _Item(tr('SMS Shield is listening for new SMS'), t('smsReceiverEnabled'), 'app', why: tr('Switch SMS Shield off and on again on the Protection tab.')),
    if (call) _Item(tr('Second Look is your caller ID & spam app'), t('callRoleHeld'), 'callRole', why: tr('Without this, calls from new numbers can\'t be checked.')),
    if (sms || call) _Item(tr('Notifications are allowed'), t('notificationsAllowed'), 'notifications', why: tr('Alerts can\'t appear without notifications.')),
    if ((sms || call) && m.containsKey('alertChannelOn'))
      _Item(tr('Scam alert notifications are switched on'), t('alertChannelOn'), 'notifications', why: tr('This kind of notification is switched off in your phone\'s settings.')),
    if (call && m.containsKey('overlayAllowed'))
      _Item(tr('Call popup can show over other apps'), t('overlayAllowed'), 'overlay', why: tr('Optional: shows who may be calling on top of the ringing screen.')),
    if (sms || call) _Item(tr('Battery saver won\'t stop Second Look'), t('batteryUnrestricted'), 'battery', why: tr('Some phones stop apps in the background to save battery.')),
  ];
}

/// "Protection check": finds what could stop SMS Shield or Call Shield from working, with a Fix button for each,
/// and lets the user send a test alert.
class ShieldHealthScreen extends StatefulWidget {
  const ShieldHealthScreen({super.key});
  @override
  State<ShieldHealthScreen> createState() => _ShieldHealthScreenState();
}

class _ShieldHealthScreenState extends State<ShieldHealthScreen> with WidgetsBindingObserver {
  Map<String, dynamic>? h;
  Map<String, dynamic> s = {};
  bool loading = true;
  String? sending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from a system settings screen: check again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    final health = await Native.instance.shieldHealth();
    Map<String, dynamic> st = s;
    try {
      st = await Native.instance.status();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      h = health;
      s = st;
      loading = false;
    });
  }

  Future<void> _fix(String target) async {
    final ok = await Native.instance.openSettings(target);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t open that screen. Open your phone\'s Settings → Apps → Second Look.'))));
    }
    await load();
  }

  Future<void> _test(String kind) async {
    setState(() => sending = kind);
    final id = await Native.instance.testAlert(kind);
    if (!mounted) return;
    setState(() => sending = null);
    notifyAlertsChanged();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(id == null
          ? tr('The test alert couldn\'t be sent.')
          : tr('Test alert sent. Check your notifications and the Alerts tab.')),
    ));
  }

  Map get _prefs => (s['prefs'] as Map?) ?? const {};

  Future<void> _pref(String key, bool on) async {
    final st = await Native.instance.trySetPref(key, on ? 'on' : 'off');
    if (!mounted) return;
    if (st == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t save. Please try again.'))));
      return;
    }
    setState(() => s = st);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = h;
    final checks = _checks(m);
    final bad = checks.where((c) => !c.ok).length;
    final available = healthAvailable(m);
    final sms = m?['smsWanted'] == true, call = m?['callWanted'] == true;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Protection check')), actions: [
        IconButton(tooltip: tr('Refresh'), onPressed: load, icon: const Icon(Icons.refresh_rounded)),
      ]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
                if (!available)
                  Panel(
                    child: Text(
                      m?['platform'] == 'ios'
                          ? tr('On iPhone, the shields are switched on in iPhone Settings. Follow the steps under each shield on the Protection tab.')
                          : tr('Protection check works in the Android app.'),
                      style: TextStyle(color: cs.onSurface.withAlpha(180), height: 1.4),
                    ),
                  )
                else ...[
                  // ---- summary
                  Panel(
                    color: SL.bg(context, bad == 0 ? 'safe' : 'warning'),
                    child: Row(children: [
                      Icon(bad == 0 ? Icons.verified_user_rounded : Icons.report_rounded, size: 34, color: SL.fg(context, bad == 0 ? 'safe' : 'warning')),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          !sms && !call
                              ? tr('Both shields are off. Switch them on on the Protection tab, then come back here.')
                              : bad == 0
                                  ? tr('Everything looks ready. Send a test alert below to be sure.')
                                  : bad == 1
                                      ? tr('1 thing needs your attention.')
                                      : tr('{n} things need your attention.', {'n': bad}),
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5, height: 1.35),
                        ),
                      ),
                    ]),
                  ),
                  if (m?['restrictedSettingsLikely'] == true) ...[
                    const SizedBox(height: 12),
                    const _RestrictedCard(),
                  ],
                  if (checks.isNotEmpty) ...[
                    SectionLabel(tr('Checks')),
                    Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      child: Column(children: [
                        for (final c in checks)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(c.ok ? Icons.check_circle_rounded : Icons.warning_rounded,
                                    color: SL.fg(context, c.ok ? 'safe' : 'warning'), size: 22),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(c.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                                  if (!c.ok && c.why != null)
                                    Text(c.why!, style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(160), height: 1.35)),
                                ]),
                              ),
                              if (!c.ok) ...[
                                const SizedBox(width: 8),
                                FilledButton.tonal(
                                  style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
                                  onPressed: () => _fix(c.fix),
                                  child: Text(tr('Fix')),
                                ),
                              ],
                            ]),
                          ),
                      ]),
                    ),
                  ],
                  if (m?['autostartPage'] == true) ...[
                    const SizedBox(height: 12),
                    Panel(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(Icons.restart_alt_rounded, color: cs.primary),
                          const SizedBox(width: 10),
                          Expanded(child: Text(tr('Allow Second Look to start on its own'), style: Theme.of(context).textTheme.titleMedium)),
                        ]),
                        const SizedBox(height: 6),
                        Text(
                          tr('Your phone may stop apps that run in the background. Allow Second Look under "Autostart" (or "Background activity") so the shields keep working.'),
                          style: TextStyle(color: cs.onSurface.withAlpha(175), height: 1.4),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () => _fix('autostart'),
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: Text(tr('Open Autostart settings')),
                        ),
                      ]),
                    ),
                  ],
                  // ---- test alerts
                  SectionLabel(tr('Test it')),
                  Panel(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(
                        tr('Sends a made-up scam through the same checks. You should see a notification and a new entry marked "Test" in Alerts.'),
                        style: TextStyle(color: cs.onSurface.withAlpha(175), height: 1.4),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: sending != null ? null : () => _test('sms'),
                        icon: sending == 'sms'
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.sms_rounded),
                        label: Text(tr('Send test SMS alert')),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: sending != null ? null : () => _test('call'),
                        icon: sending == 'call'
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.call_rounded),
                        label: Text(tr('Send test call alert')),
                      ),
                    ]),
                  ),
                  // ---- options
                  SectionLabel(tr('Options')),
                  Panel(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.list_alt_rounded),
                        title: Text(tr('List every checked SMS and call in Alerts')),
                        subtitle: Text(tr('Off: only suspicious ones are kept. Everything stays on this phone.')),
                        value: '${_prefs['log_all'] ?? ''}' != 'off',
                        onChanged: (v) => _pref('log_all', v),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.picture_in_picture_alt_rounded),
                        title: Text(tr('Show a popup while an unknown number rings')),
                        subtitle: Text(tr('Needs "Display over other apps".')),
                        value: '${_prefs['call_popup'] ?? ''}' != 'off',
                        onChanged: (v) => _pref('call_popup', v),
                      ),
                    ]),
                  ),
                ],
              ]),
            ),
    );
  }
}

/// Android 13+ blocks SMS access for apps installed from outside an app store until the user allows "restricted settings".
class _RestrictedCard extends StatelessWidget {
  const _RestrictedCard();

  @override
  Widget build(BuildContext context) {
    final fg = SL.fg(context, 'danger');
    final steps = [
      tr('Tap "Open app settings" below (or go to Settings → Apps → Second Look).'),
      tr('Tap ⋮ in the top-right corner.'),
      tr('Tap "Allow restricted settings" and confirm with your PIN or fingerprint.'),
      tr('Come back here and switch SMS Shield on again.'),
    ];
    return Panel(
      color: SL.bg(context, 'danger'),
      borderColor: fg.withAlpha(110),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.lock_rounded, color: fg, size: 30),
          const SizedBox(width: 12),
          Expanded(child: Text(tr('Android is blocking SMS access for this app'), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: fg))),
        ]),
        const SizedBox(height: 8),
        Text(
          tr('Apps installed from outside an app store need one extra step before they can read SMS. It takes about a minute.'),
          style: const TextStyle(height: 1.4),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12)),
          child: Text(tr('Settings → Apps → Second Look → ⋮ (top-right) → Allow restricted settings'),
              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: fg.withAlpha(30), shape: BoxShape.circle),
                child: Text('${i + 1}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: fg)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(steps[i], style: const TextStyle(height: 1.4))),
            ]),
          ),
        const SizedBox(height: 6),
        Text(tr('The menu name may be a little different on your phone.'),
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(160))),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => Native.instance.openSettings('app'),
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(tr('Open app settings')),
        ),
      ]),
    );
  }
}
