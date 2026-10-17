import 'package:flutter/material.dart';

import '../cloud.dart';
import '../community.dart';
import '../i18n/i18n.dart';
import '../i18n/reasons.dart';
import '../native.dart';
import '../legal/legal.dart';
import 'plus.dart';
import 'shield_health.dart';
import '../theme.dart';
import '../voice.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic> s = {};
  Map<String, dynamic> sec = {};
  List<Map<String, dynamic>> reports = [];
  Map<String, dynamic>? health;
  final name = TextEditingController();
  final number = TextEditingController();

  // Voices for the current language (loaded again when the language changes).
  List<Map<String, dynamic>> voices = [];
  String? voicesLang;
  bool voicesLoading = false;
  String? previewing;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    number.dispose();
    if (previewing != null) Voice.stop();
    super.dispose();
  }

  Future<void> _loadVoices() async {
    final lang = L10n.lang.value;
    voicesLang = lang;
    voicesLoading = true;
    final v = await Voice.voices(lang);
    if (!mounted) return;
    if (L10n.lang.value != lang) {
      // The language changed while loading: load again on the next build.
      setState(() {
        voicesLoading = false;
        voicesLang = null;
      });
      return;
    }
    setState(() {
      voices = v;
      voicesLoading = false;
    });
  }

  Future<void> _preview(String id) async {
    setState(() => previewing = id);
    final ok = await Voice.speak(tr('This is how Second Look will read your results.'), voice: id);
    if (!mounted) return;
    if (!ok) {
      setState(() => previewing = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('The voice for {lang} isn\'t installed on this device. Add it in your phone\'s text-to-speech settings.',
            {'lang': L10n.names[L10n.lang.value]})),
      ));
      return;
    }
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && previewing == id) setState(() => previewing = null);
    });
  }

  Future<void> load() async {
    final st = await Native.instance.status();
    final r = await Native.instance.reports();
    final sc = await Native.instance.securityStatus();
    final hh = await Native.instance.shieldHealth();
    if (!mounted) return;
    setState(() {
      s = st;
      sec = sc;
      health = hh;
      reports = r;
      name.text = (st['trustedName'] as String?) ?? '';
      number.text = (st['trustedNumber'] as String?) ?? '';
    });
  }

  /// One voice choice: radio, label, optional note, and a ▶ preview button.
  Widget _voiceRow(String id, String label, String? note) {
    final selected = Voice.voiceName == id;
    final playing = previewing == id;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        await Voice.setVoiceName(id);
        if (mounted) setState(() {});
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
              color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface.withAlpha(120)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
              if (note != null) Text(note, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withAlpha(140))),
            ]),
          ),
          if (id.isEmpty)
            const SizedBox(width: 48)
          else
            IconButton(
              tooltip: tr('Play a sample'),
              onPressed: () async {
                if (playing) {
                  await Voice.stop();
                  if (mounted) setState(() => previewing = null);
                } else {
                  await _preview(id);
                }
              },
              icon: Icon(playing ? Icons.stop_circle_rounded : Icons.play_circle_rounded),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final web = Native.instance.isWeb || s['platform'] == 'web';
    final here = web ? tr('this browser') : tr('this phone');
    if (voicesLang != L10n.lang.value && !voicesLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadVoices();
      });
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('Settings')), actions: const [LanguageButton(), SizedBox(width: 8)]),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        SectionLabel(tr('Language')),
        Panel(
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in L10n.supported)
              ChoiceChip(
                label: Text(L10n.names[c]!),
                selected: L10n.lang.value == c,
                onSelected: (_) async {
                  await L10n.set(c);
                  if (mounted) setState(() {});
                },
              ),
          ]),
        ),
        SectionLabel(tr('Voice')),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.record_voice_over_rounded),
              title: Text(tr('Read results aloud automatically')),
              subtitle: Text(tr('Off: results are read only when you tap Listen. Uses your phone\'s own voice; nothing is sent anywhere.')),
              value: Voice.auto,
              onChanged: (v) async {
                await Voice.setAuto(v);
                if (mounted) setState(() {});
              },
            ),
            const Divider(height: 20),
            Text(tr('Choose a voice'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            _voiceRow('', tr('Phone\'s default voice'), null),
            if (voicesLoading && voices.isEmpty)
              const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))
            else
              for (var i = 0; i < voices.length; i++)
                _voiceRow('${voices[i]['id']}', tr('Voice {n}', {'n': i + 1}), voices[i]['network'] == true ? tr('Needs internet') : null),
            if (!voicesLoading && voices.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tr('No other voices found for this language on this device.'), style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(150))),
              ),
            const Divider(height: 24),
            Text(tr('Speed'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: Text(tr('Slow')), icon: const Icon(Icons.slow_motion_video_rounded)),
                ButtonSegment(value: false, label: Text(tr('Normal')), icon: const Icon(Icons.play_arrow_rounded)),
              ],
              selected: {Voice.slow},
              onSelectionChanged: (v) async {
                await Voice.setSlow(v.first);
                if (mounted) setState(() {});
              },
            ),
          ]),
        ),
        if (Cloud.configured) ...[
          const SizedBox(height: 8),
          Panel(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlusScreen())),
            child: Row(children: [
              const Icon(Icons.workspace_premium_rounded, color: Color(0xFF9A5B00), size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Second Look Plus', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  Text(tr('Unlimited deep checks, no ads, more devices')),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurface.withAlpha(120)),
            ]),
          ),
        ],
        if (Cloud.configured) ...[
          SectionLabel(tr('Community protection')),
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              secondary: const Icon(Icons.groups_rounded),
              title: Text(tr('Use community reports')),
              subtitle: Text(web
                  ? tr('Show what other users reported when you check a number.')
                  : tr('Show what other users reported when you check a number, and let Call Shield warn about numbers many people reported. '
                      'Call Shield uses a list downloaded to this phone; callers\' numbers are never sent.')),
              value: ((s['prefs'] as Map?)?['community_off'] ?? '') != '1',
              onChanged: (v) async {
                var st = await Native.instance.setPref('community_off', v ? '' : '1');
                if (v) {
                  st = await Native.instance.setPref('community_sync', '');
                  Community.syncIfDue(st); // download the list for Call Shield now, not at the next app start
                }
                if (mounted) setState(() => s = st);
              },
            ),
          ),
        ],
        SectionLabel(tr('Trusted person')),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('When something looks like a scam, you get a button to ask this person to check it with you. Nothing is sent automatically.'),
                style: TextStyle(color: cs.onSurface.withAlpha(170))),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: InputDecoration(labelText: tr('Name'), hintText: tr('e.g. Ayesha (daughter)'))),
            const SizedBox(height: 10),
            TextField(controller: number, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: tr('Mobile number'))),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                await Native.instance.setTrusted(name.text.trim(), number.text.trim());
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Saved on {place}', {'place': here}))));
              },
              child: Text(tr('Save')),
            ),
          ]),
        ),
        SectionLabel(tr('Numbers you marked ({n})', {'n': reports.length})),
        if (reports.isEmpty)
          Panel(child: Text('${tr('Numbers you report or trust appear here.')} ${s['platform'] == 'ios' ? tr('Reported numbers are blocked and labelled by Call Shield.') : tr('Call Shield warns you when they call again.')}'))
        else
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              for (final r in reports)
                ListTile(
                  leading: Icon(r['kind'] == 'safe' ? Icons.verified_rounded : Icons.block_rounded),
                  title: Text('${r['number']}'),
                  subtitle: Text(_reportLabel(r)),
                  trailing: IconButton(
                    tooltip: tr('Remove'),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () async {
                      await Native.instance.removeReport(r['number'] as String);
                      load();
                    },
                  ),
                ),
            ]),
          ),
        if (web) ...[
          SectionLabel(tr('On this laptop')),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Check(tr('Checks run in this browser. Nothing you paste is uploaded.'), true),
              _Check(tr('Alerts and marked numbers are saved only in this browser'), true),
              const SizedBox(height: 6),
              Text(tr('SMS Shield, Call Shield and app lock need a phone. Install Second Look on Android or iPhone to switch them on.'),
                  style: TextStyle(color: cs.onSurface.withAlpha(170))),
            ]),
          ),
        ] else ...[
          if (s['platform'] != 'ios') ...[
            SectionLabel(tr('Shields')),
            Panel(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                leading: Icon(Icons.health_and_safety_rounded, color: healthIssues(health) > 0 ? SL.fg(context, 'warning') : null),
                title: Text(tr('Protection check')),
                subtitle: Text(healthIssues(health) > 0
                    ? tr('Something may stop your shields. Tap to fix.')
                    : tr('See if anything stops your shields, and send a test alert')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShieldHealthScreen()));
                  if (mounted) load();
                },
              ),
            ),
          ],
          SectionLabel(tr('Security')),
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.fingerprint_rounded),
                title: Text(tr('App lock')),
                subtitle: Text(tr('Ask for fingerprint, face or phone PIN to open Second Look')),
                value: s['appLock'] == true,
                onChanged: (v) async {
                  final err = await Native.instance.setAppLock(v);
                  if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                  load();
                },
              ),
              if (s['platform'] != 'ios')
                SwitchListTile(
                  secondary: const Icon(Icons.screenshot_monitor_rounded),
                  title: Text(tr('Screen protection')),
                  subtitle: Text(tr('Blocks screenshots and hides the app from screen-sharing and remote-control apps')),
                  value: s['screenProtection'] != false,
                  onChanged: (v) async {
                    await Native.instance.setScreenProtection(v);
                    load();
                  },
                ),
            ]),
          ),
          const SizedBox(height: 12),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Security check'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              _Check(tr('Your data is encrypted on this phone'), sec['encryptedStorage'] == true),
              _Check(tr('Messages, numbers and contacts never leave this phone'), sec['privateChecks'] != false),
              if (sec.containsKey('rulesIntact')) _Check(tr('Scam rules are the original, untouched files'), sec['rulesIntact'] != false),
              if (sec['signatureConfigured'] == true) _Check(tr('This is the official, unmodified app'), sec['signatureOk'] != false),
              _Check(tr('No debugger attached'), sec['debugger'] != true),
              _Check(tr('No hacking tools inside the app'), sec['hooking'] != true),
              _Check(s['platform'] == 'ios' ? tr('iPhone is not jailbroken') : tr('Phone is not rooted'), sec['rooted'] != true),
            ]),
          ),
        ],
        SectionLabel(tr('Your privacy')),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Promise(Icons.phone_android_rounded, tr('Checks run on {place}', {'place': here}), tr('SMS text, links and numbers are analysed on the device. Nothing is uploaded unless you tap Deep check.')),
            if (Cloud.configured)
              _Promise(Icons.travel_explore_rounded, tr('Deep check is your choice'), tr('Only when you tap Deep check is the link itself sent to our server for an online check. Never your messages, numbers or contacts.')),
            _Promise(Icons.contacts_rounded, tr('Your contacts stay yours'), tr('Second Look never reads or uploads your address book, so it never builds a names database about you or your friends.')),
            _Promise(Icons.toggle_on_rounded, tr('You decide'), tr('Each shield is off until you switch it on, and you can switch it off at any time.')),
            _Promise(Icons.delete_outline_rounded, tr('Delete everything'), tr('One tap removes alerts, marked numbers and settings.')),
          ]),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: cs.error),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(tr('Delete all data?')),
                content: Text([
                  tr('This removes your alerts, marked numbers, trusted person and settings from {place}.', {'place': here}),
                  if (Cloud.configured) tr('It also deletes your deep-check data on our server.'),
                  if (!web) tr('Shields will be switched off.'),
                  if (Cloud.configured) tr('If you have Plus, you can get it back later with "Restore purchases".'),
                ].join(' ')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Delete'))),
                ],
              ),
            );
            if (ok == true) {
              var serverNote = '';
              if (Cloud.configured) {
                try {
                  await Cloud.instance.forget();
                } catch (_) {
                  serverNote = ' ${tr('We couldn\'t reach our server, so your deep-check data there will be deleted automatically after 12 months of no use, or try again when online.')}';
                }
              }
              await Native.instance.deleteAllData();
              Cloud.instance.reset();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Your data was deleted.')}$serverNote')));
              load();
            }
          },
          icon: const Icon(Icons.delete_forever_rounded),
          label: Text(tr('Delete all my data')),
        ),
        SectionLabel(tr('Legal')),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.gavel_rounded),
              title: Text(tr('Terms of Use')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => LegalDocScreen.open(context, 'terms'),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_rounded),
              title: Text(tr('Privacy Policy')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => LegalDocScreen.open(context, 'privacy'),
            ),
            if (Cloud.configured)
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(tr('Your data on our server')),
                subtitle: Text(tr('See exactly what is stored')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showServerData(context),
              ),
            ListTile(
              leading: const Icon(Icons.support_agent_rounded),
              title: Text(tr('Grievance Officer')),
              subtitle: SelectableText('${Operator.grievanceName} · ${Operator.grievanceEmail}'),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(tr('Open-source licences')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showLicensePage(context: context, applicationName: 'Second Look', applicationLegalese: '© ${Operator.name}'),
            ),
          ]),
        ),
        SectionLabel(tr('About')),
        Panel(
          child: Text(
            [
              tr('Second Look 1.0 by {operator}. Rules for Indian scams (KYC, UPI, digital arrest, courier, job and investment fraud, fake payments), registered SMS sender checks, and TRAI number series.', {'operator': Operator.name}),
              tr('Results are automated opinions, not guarantees: it can miss new tricks or warn about something genuine. When money or OTPs are involved, check with the organisation directly.'),
              tr('Second Look is not affiliated with any bank, app, company or government body named in it.'),
            ].join(' '),
            style: TextStyle(color: cs.onSurface.withAlpha(170)),
          ),
        ),
      ]),
    );
  }
}

/// The label of a number the user marked (Block / Spam / Fraud / Safe, or an older report type).
String _reportLabel(Map<String, dynamic> r) {
  final type = '${r['type'] ?? ''}';
  switch (type) {
    case 'blocked':
      return tr('Blocked');
    case 'spam':
      return tr('Spam');
    case 'fraud':
      return tr('Fraud');
    case 'safe':
      return tr('Safe');
  }
  return reportTypeLabel(L10n.lang.value, type) ?? '${r['label'] ?? type}';
}

class _Check extends StatelessWidget {
  const _Check(this.label, this.ok);
  final String label;
  final bool ok;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.warning_rounded, color: SL.fg(context, ok ? 'safe' : 'danger'), size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14.5))),
        ]),
      );
}

class _Promise extends StatelessWidget {
  const _Promise(this.icon, this.title, this.text);
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(text, style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(160))),
            ]),
          ),
        ]),
      );
}

Future<void> _showServerData(BuildContext context) async {
  Map<String, dynamic>? d;
  String? err;
  try {
    d = await Cloud.instance.myData();
  } catch (e) {
    err = '$e';
  }
  if (!context.mounted) return;
  String when(Object? secs) {
    final v = (secs as num?)?.toDouble() ?? 0;
    if (v <= 0) return tr('none');
    final t = DateTime.fromMillisecondsSinceEpoch((v * 1000).round());
    return '${t.day}/${t.month}/${t.year}';
  }
  final rows = d == null
      ? <List<String>>[]
      : [
          [tr('Random install ID'), '${d['installId']}'],
          [tr('First seen'), when(d['created'])],
          [tr('Plus until'), when(d['plusUntil'])],
          [tr('Extra checks from ads'), '${d['adCredits']}'],
          [tr('Linked to another device'), d['linkedToAnotherDevice'] == true ? tr('Yes') : tr('No')],
          [tr('Devices linked to this one'), '${d['devicesLinkedToThis']}'],
          [tr('Deep checks used'), ((d['deepChecksPerDay'] as List?) ?? []).map((e) => '${(e as Map)['day']}: ${e['count']}').join(', ').ifEmpty(tr('none'))],
          [tr('Purchases recorded'), '${d['purchasesRecorded']}'],
          [tr('Never stored'), '${d['notStored']}'],
        ];
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Your data on our server'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            if (err != null) Text(tr('Couldn\'t reach our server: {error}', {'error': err})),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 150, child: Text(r[0], style: TextStyle(color: Theme.of(c).colorScheme.onSurface.withAlpha(150)))),
                  Expanded(child: SelectableText(r[1], style: const TextStyle(fontWeight: FontWeight.w600))),
                ]),
              ),
            const SizedBox(height: 10),
            Text(tr('To delete it, use "Delete all my data" in Settings.')),
          ]),
        ),
      ),
    ),
  );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
