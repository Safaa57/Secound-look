import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../cloud.dart';
import '../i18n/i18n.dart';
import '../i18n/reasons.dart';
import '../native.dart';
import 'community_card.dart';
import 'deep_check.dart';
import '../theme.dart';
import '../voice.dart';
import 'common.dart';

const _kindIcons = <String, IconData>{
  'person': Icons.person_rounded,
  'business': Icons.apartment_rounded,
  'telemarketer': Icons.campaign_rounded,
  'bot': Icons.smart_toy_rounded,
  'foreign': Icons.public_rounded,
  'spoofed': Icons.masks_rounded,
  'scam': Icons.gpp_bad_rounded,
  'email': Icons.alternate_email_rounded,
  'unknown': Icons.help_outline_rounded,
};

String _kindLevel(String kind) =>
    {'scam': 'danger', 'spoofed': 'danger', 'bot': 'warning', 'foreign': 'warning', 'telemarketer': 'warning'}[kind] ?? 'safe';

/// Full explanation of one check: verdict, who sent it, why, and what to do.
class VerdictView extends StatelessWidget {
  const VerdictView({super.key, required this.result, this.trustedName, this.trustedNumber, this.onChanged});
  final Map<String, dynamic> result;
  final String? trustedName, trustedNumber;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final level = (result['level'] as Map)['key'] as String;
    final label = trLevel(result['level'] as Map, kind: result['kind'] as String?);
    final score = (result['score'] as num).toInt();
    final info = (result['info'] as Map?)?.cast<String, dynamic>() ?? {};
    final reasons = (result['reasons'] as List? ?? []).cast<Map>().where((r) => (r['weight'] as num) != 0).toList();
    final advice = (result['advice'] as List? ?? []).cast<String>();
    final number = (info['numberDetails'] as Map?)?.cast<String, dynamic>();
    final caller = (info['caller'] as Map?)?.cast<String, dynamic>();
    final sender = (info['sender'] as Map?)?.cast<String, dynamic>();
    final senderNumber = (sender?['number'] as Map?)?.cast<String, dynamic>();
    final phones = (info['phones'] as List? ?? []).cast<Map>();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Verdict
      Panel(
        color: SL.bg(context, level),
        borderColor: SL.fg(context, level).withAlpha(90),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: SL.fg(context, level).withAlpha(36), shape: BoxShape.circle),
              child: Icon(SL.icon(level), color: SL.fg(context, level), size: 32),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800, color: SL.fg(context, level), letterSpacing: -0.4, height: 1.15))),
          ]),
          const SizedBox(height: 10),
          Text(_oneLiner(level, result['kind'] as String?), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.4)),
          const SizedBox(height: 14),
          _RiskBar(score: score),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(tr('Risk {n} / 100', {'n': score}), style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            Text(_kindTitle(result['kind'] as String), style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(150))),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: Text(tr('Automated opinion, not a guarantee. Not affiliated with any bank or company named here.'),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withAlpha(140))),
            ),
            ListenButton(key: ObjectKey(result), result: result, color: SL.fg(context, level)),
          ]),
        ]),
      ),
      if (caller != null || number != null) ...[
        const SizedBox(height: 12),
        CallerCard(details: number, caller: caller, onChanged: onChanged),
      ],
      if (info['community'] is Map) ...[
        const SizedBox(height: 12),
        CommunityCard(key: ValueKey('${(info['community'] as Map)['number']}'), summary: (info['community'] as Map).cast<String, dynamic>()),
      ],
      if (sender != null) ...[
        const SizedBox(height: 12),
        _SenderCard(sender: sender),
        if (senderNumber != null) ...[const SizedBox(height: 12), CallerCard(details: senderNumber, caller: null, onChanged: onChanged)],
      ],
      for (final p in phones) ...[const SizedBox(height: 12), CallerCard(details: p.cast<String, dynamic>(), caller: null, compact: true, onChanged: onChanged)],
      DeepCheckCard(key: ValueKey(Cloud.linksIn(result).join('|')), urls: Cloud.linksIn(result)),
      SectionLabel(tr('Why')),
      if (reasons.isEmpty)
        Panel(child: Text(tr('None of the known scam patterns matched.'), style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(170))))
      else
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Column(children: [for (final r in reasons) _ReasonRow(r.cast<String, dynamic>())]),
        ),
      SectionLabel(tr('What to do now')),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < advice.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withAlpha(30), shape: BoxShape.circle),
                  child: Text('${i + 1}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(trAdvice(advice[i]), style: const TextStyle(fontSize: 15, height: 1.45))),
              ]),
            ),
        ]),
      ),
      if (level != 'safe') ...[
        const SizedBox(height: 14),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: SL.fg(context, 'danger'), foregroundColor: Colors.white),
          onPressed: () => Native.instance.dial('1930'),
          icon: const Icon(Icons.call_rounded),
          label: Text(tr('Lost money? Call 1930 now')),
        ),
        if ((trustedNumber ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Native.instance.smsTo(trustedNumber!,
                tr('Second Look flagged something on my phone as "{label}". Can you check it with me before I do anything?', {'label': label.toLowerCase()})),
            icon: const Icon(Icons.family_restroom_rounded),
            label: Text(tr('Ask {name} to check', {'name': trustedName?.isNotEmpty == true ? trustedName : tr('my trusted person')})),
          ),
        ],
      ],
    ]);
  }

  static String _kindTitle(String k) =>
      tr({'sms': 'SMS', 'message': 'Message', 'link': 'Link', 'number': 'Phone number', 'call': 'Call', 'upi': 'UPI ID', 'payment': 'Payment screenshot', 'document': 'Document'}[k] ?? k);

  /// One plain sentence under the verdict: what it means for the person right now.
  static String _oneLiner(String level, String? kind) {
    if (kind == 'document') {
      return level == 'safe'
          ? tr('No signs of forgery found, but only the issuer can confirm a document is genuine.')
          : tr('Don\'t pay, sign or share anything because of this document until the issuer confirms it.');
    }
    if (kind == 'payment') {
      return level == 'safe'
          ? tr('A screenshot can\'t prove a payment. Check the money in your own bank app.')
          : tr('Don\'t hand over anything until the money shows in your own bank app.');
    }
    switch (level) {
      case 'danger':
        return tr('Don\'t click, pay, call back or share any code.');
      case 'warning':
        return tr('Be careful. Check with the organisation directly before you act.');
      default:
        return tr('Nothing obviously wrong, but stay alert if money or codes are involved.');
    }
  }
}

class _RiskBar extends StatelessWidget {
  const _RiskBar({required this.score});
  final int score;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final x = (score.clamp(1, 99) / 100) * c.maxWidth;
        return SizedBox(
          height: 18,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(
              left: 0,
              right: 0,
              top: 5,
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: LinearGradient(stops: const [0, .2, .2, .5, .5, 1], colors: [
                    SL.fg(context, 'safe'), SL.fg(context, 'safe'), SL.amber, SL.amber, SL.fg(context, 'danger'), SL.fg(context, 'danger'),
                  ]),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              left: x - 3,
              top: 0,
              child: Container(width: 6, height: 18, decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurface, borderRadius: BorderRadius.circular(3))),
            ),
          ]),
        );
      });
}

class _ReasonRow extends StatelessWidget {
  const _ReasonRow(this.r);
  final Map<String, dynamic> r;
  @override
  Widget build(BuildContext context) {
    final w = (r['weight'] as num).toInt();
    final lv = w < 0 ? 'safe' : (w >= 35 ? 'danger' : (w >= 15 ? 'warning' : 'safe'));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(color: SL.bg(context, lv), borderRadius: BorderRadius.circular(8)),
          child: Text(w > 0 ? '+$w' : '$w', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: SL.fg(context, lv))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(trReasonTitle(r), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
            const SizedBox(height: 3),
            Text(trReasonDetail(r), style: TextStyle(fontSize: 14, height: 1.4, color: Theme.of(context).colorScheme.onSurface.withAlpha(170))),
          ]),
        ),
      ]),
    );
  }
}

class _SenderCard extends StatelessWidget {
  const _SenderCard({required this.sender});
  final Map<String, dynamic> sender;
  @override
  Widget build(BuildContext context) {
    final kind = sender['kind'] as String? ?? 'unknown';
    final lv = kind == 'business' ? 'safe' : (kind == 'person' ? 'warning' : 'warning');
    return Panel(
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: SL.bg(context, lv), borderRadius: BorderRadius.circular(14)),
          child: Icon(_kindIcons[kind == 'business' ? 'business' : kind] ?? Icons.sms_rounded, color: SL.fg(context, lv)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('From {who}', {'who': sender['raw']}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 2),
            Text(callerLabel(L10n.lang.value, 'sender_$kind') ?? (sender['label'] as String? ?? ''), style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(170))),
            if (kind == 'business')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Registered sender IDs end in -T (transactions), -S (service), -P (promotions) or -G (government).'),
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(140))),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Who is calling: caller type (person / business / telemarketer / bot / scam), number facts and lookup buttons.
class CallerCard extends StatelessWidget {
  const CallerCard({super.key, required this.details, required this.caller, this.compact = false, this.onChanged});
  final Map<String, dynamic>? details;
  final Map<String, dynamic>? caller;
  final bool compact;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final d = details ?? {};
    final kind = caller?['kind'] as String?;
    final cs = Theme.of(context).colorScheme;
    final e164 = (d['e164'] as String?) ?? '';
    final digits = e164.replaceAll(RegExp(r'\D'), '');
    final rows = <List<String>>[
      if (d['countryName'] != null) [tr('Country'), '${d['countryName']}  ${d['callingCode'] ?? ''}'],
      if (d['circle'] != null) [tr('State'), '${d['circle']}'],
      if (d['location'] != null) [tr('City'), '${d['location']}'],
      [tr('Type'), numberTypeLabel(L10n.lang.value, '${d['typeLabel'] ?? 'Unknown'}') ?? '${d['typeLabel'] ?? tr('Unknown')}'],
      if (d['carrier'] != null) [tr('Network'), '${d['carrier']}'],
      if (d['series'] != null) [tr('Series'), '${d['series']}'],
      if (d['valid'] == false) [tr('Valid'), tr('No, this number can\'t exist')],
    ];
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: SL.bg(context, _kindLevel(kind ?? 'person')), borderRadius: BorderRadius.circular(14)),
            child: Icon(_kindIcons[kind ?? 'unknown'] ?? Icons.phone_rounded, color: SL.fg(context, _kindLevel(kind ?? 'person'))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d['international'] ?? d['e164'] ?? d['input'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, fontFeatures: [FontFeature.tabularFigures()])),
              if (caller != null) Text(callerLabel(L10n.lang.value, '${caller!['kind']}') ?? '${caller!['label']}', style: TextStyle(fontWeight: FontWeight.w700, color: SL.fg(context, _kindLevel(kind ?? 'unknown')))),
            ]),
          ),
        ]),
        if (caller?['detail'] != null) ...[
          const SizedBox(height: 10),
          Text(callerLabel(L10n.lang.value, '${caller!['kind']}_detail') ?? '${caller!['detail']}', style: TextStyle(fontSize: 14, color: cs.onSurface.withAlpha(170))),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 18, runSpacing: 10, children: [
          for (final r in rows)
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 260),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r[0].toUpperCase(), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: cs.onSurface.withAlpha(130))),
                const SizedBox(height: 2),
                Text(r[1], style: const TextStyle(fontSize: 15)),
              ]),
            ),
        ]),
        if (d['carrier'] != null || d['circle'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(tr('State and network show where the number was first issued. People can move or switch networks and keep the same number.'),
                style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(130))),
          ),
        if (!compact && digits.isNotEmpty) ...[
          const Divider(height: 28),
          Text(tr('Who is it?'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(tr('Second Look never uploads anyone\'s contacts, so it doesn\'t keep a names database. On India\'s newer networks, your phone itself may show the caller\'s registered name (CNAP). You can also search the web for reports about this number:'),
              style: TextStyle(fontSize: 13.5, color: cs.onSurface.withAlpha(160))),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _LinkChip(tr('Search the web'), Icons.travel_explore_rounded, () => Native.instance.openUrl('https://www.google.com/search?q=${Uri.encodeQueryComponent('"$e164" scam')}')),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _report(context, e164),
                icon: const Icon(Icons.flag_rounded),
                label: Text(tr('Report')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Native.instance.report(e164, 'safe', tr('Genuine / safe caller'), 'safe');
                  onChanged?.call();
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Marked as trusted on this phone'))));
                },
                icon: const Icon(Icons.verified_rounded),
                label: Text(tr('Trust')),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Future<void> _report(BuildContext context, String e164) async {
    final types = [
      ['fake_bank', tr('Fake bank, KYC or UPI call')],
      ['fake_police', tr('Fake police or digital arrest')],
      ['job_invest', tr('Job, task or investment scam')],
      ['courier', tr('Fake courier, customs or bill')],
      ['family', tr('Pretending to be family')],
      ['sextortion', tr('Blackmail or sextortion')],
      ['scam', tr('Other scam')],
      ['spam', tr('Spam, sales or robocall')],
    ];
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => _ReportSheet(types: types),
    );
    if (picked == null) return;
    final t = picked['type'] as List<String>;
    await Native.instance.report(e164, t[0], t[1], t[0] == 'spam' ? 'spam' : 'scam');
    var msg = tr('Reported. Second Look will warn you if this number contacts you again.');
    if (picked['share'] == true && Cloud.configured) {
      try {
        await Cloud.instance.communityReport(e164, t[0], claimed: picked['claimed'] as String, note: picked['note'] as String);
        msg = tr('Reported and shared with the community. Thank you for protecting others.');
      } catch (_) {
        msg = tr('Saved on this phone. We couldn\'t share it with the community right now.');
      }
    }
    onChanged?.call();
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.types});
  final List<List<String>> types;
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  List<String>? type;
  bool share = Cloud.configured;
  final claimed = TextEditingController();
  final note = TextEditingController();

  @override
  void dispose() {
    claimed.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Report this number'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(tr('Only report a number that actually contacted you.'), style: TextStyle(color: cs.onSurface.withAlpha(160))),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in widget.types)
                ChoiceChip(label: Text(t[1]), selected: type == t, onSelected: (_) => setState(() => type = t)),
            ]),
            const SizedBox(height: 12),
            TextField(controller: claimed, maxLength: 60, decoration: InputDecoration(labelText: tr('Who did they say they were? (optional)'), hintText: tr('e.g. bank customer care'))),
            TextField(
              controller: note,
              maxLength: 200,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(labelText: tr('What happened? (optional)'), hintText: tr('e.g. Asked for OTP to stop card blocking'), helperText: tr('Don\'t include names or personal details.')),
            ),
            if (Cloud.configured)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: share,
                onChanged: (v) => setState(() => share = v),
                title: Text(tr('Warn other Second Look users')),
                subtitle: Text(tr('Shares the number, reason and your note without your name. You can delete your reports from Settings.')),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: type == null ? null : () => Navigator.pop(context, {'type': type, 'share': share, 'claimed': claimed.text.trim(), 'note': note.text.trim()}),
              child: Text(tr('Submit report')),
            ),
          ]),
        ),
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        onPressed: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );
}
