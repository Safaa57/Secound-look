import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../cloud.dart';
import '../i18n/i18n.dart';
import '../i18n/reasons.dart';
import '../native.dart';
import 'block_sheet.dart';
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

/// One check at a glance: a verdict ring with a one-word verdict, the top reasons, big action buttons,
/// then who sent it, community reports and what to do. Details sit behind "Learn more".
class VerdictView extends StatelessWidget {
  const VerdictView({super.key, required this.result, this.trustedName, this.trustedNumber, this.onChanged});
  final Map<String, dynamic> result;
  final String? trustedName, trustedNumber;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final level = '${(result['level'] as Map?)?['key'] ?? 'safe'}';
    final kind = result['kind'] as String?;
    final label = trLevel((result['level'] as Map?) ?? const {'key': 'safe'}, kind: kind);
    final score = ((result['score'] as num?) ?? 0).toInt();
    final info = (result['info'] as Map?)?.cast<String, dynamic>() ?? {};
    final reasons = (result['reasons'] as List? ?? []).whereType<Map>().where((r) => ((r['weight'] as num?) ?? 0) != 0).toList();
    final advice = (result['advice'] as List? ?? []).map((e) => '$e').toList();
    final number = (info['numberDetails'] as Map?)?.cast<String, dynamic>();
    final caller = (info['caller'] as Map?)?.cast<String, dynamic>();
    final sender = (info['sender'] as Map?)?.cast<String, dynamic>();
    final senderNumber = (sender?['number'] as Map?)?.cast<String, dynamic>();
    final phones = (info['phones'] as List? ?? []).whereType<Map>();
    final phoneDetails = number ?? senderNumber;
    final e164 = '${phoneDetails?['e164'] ?? ''}';
    final hasNumber = e164.replaceAll(RegExp(r'\D'), '').length >= 7;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _VerdictHero(result: result, level: level, kind: kind, score: score),
      const SizedBox(height: 12),
      _Actions(level: level, e164: hasNumber ? e164 : null, onChanged: onChanged),
      SectionLabel(tr('Why'), icon: Icons.insights_rounded),
      if (reasons.isEmpty)
        Panel(
          child: Row(children: [
            Icon(Icons.check_circle_rounded, color: SL.fg(context, 'safe')),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('None of the known scam patterns matched.'), style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(190)))),
          ]),
        )
      else
        _ReasonList(reasons: [for (final r in reasons) r.cast<String, dynamic>()]),
      if (info['community'] is Map) ...[
        const SizedBox(height: 12),
        CommunityCard(key: ValueKey('${(info['community'] as Map)['number']}'), summary: (info['community'] as Map).cast<String, dynamic>()),
      ],
      if (caller != null || number != null) ...[
        const SizedBox(height: 12),
        CallerCard(details: number, caller: caller, onChanged: onChanged),
      ],
      if (sender != null) ...[
        const SizedBox(height: 12),
        _SenderCard(sender: sender),
        if (senderNumber != null) ...[const SizedBox(height: 12), CallerCard(details: senderNumber, caller: null, onChanged: onChanged)],
      ],
      for (final p in phones) ...[const SizedBox(height: 12), CallerCard(details: p.cast<String, dynamic>(), caller: null, compact: true, onChanged: onChanged)],
      DeepCheckCard(key: ValueKey(Cloud.linksIn(result).join('|')), urls: Cloud.linksIn(result)),
      if (advice.isNotEmpty) ...[
        SectionLabel(tr('What to do now'), icon: Icons.checklist_rounded),
        Panel(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < advice.length && i < 2; i++) _AdviceRow(i + 1, advice[i]),
            if (advice.length > 2)
              LearnMore(
                label: tr('Show all steps'),
                child: Column(children: [for (var i = 2; i < advice.length; i++) _AdviceRow(i + 1, advice[i])]),
              ),
          ]),
        ),
      ],
      if (level != 'safe' && (trustedNumber ?? '').isNotEmpty) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Native.instance.smsTo(trustedNumber!,
              tr('Second Look flagged something on my phone as "{label}". Can you check it with me before I do anything?', {'label': label.toLowerCase()})),
          icon: const Icon(Icons.family_restroom_rounded),
          label: Text(tr('Ask {name} to check', {'name': trustedName?.isNotEmpty == true ? trustedName : tr('my trusted person')})),
        ),
      ],
    ]);
  }
}

/// One plain sentence under the verdict: what it means for the person right now.
String verdictLine(String level, String? kind) {
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

/// The verdict in one or two words.
String verdictWord(String level, String? kind) {
  if (level == 'danger') return tr('Likely scam');
  if (level == 'warning') return tr('Suspicious');
  if (kind == 'payment' || kind == 'document') return tr('No red flags');
  return tr('Looks safe');
}

String _kindTitle(String? k) =>
    tr({'sms': 'SMS', 'message': 'Message', 'link': 'Link', 'number': 'Phone number', 'call': 'Call', 'upi': 'UPI ID', 'payment': 'Payment screenshot', 'document': 'Document'}[k] ?? (k ?? ''));

class _VerdictHero extends StatelessWidget {
  const _VerdictHero({required this.result, required this.level, required this.kind, required this.score});
  final Map<String, dynamic> result;
  final String level;
  final String? kind;
  final int score;

  @override
  Widget build(BuildContext context) {
    final fg = SL.fg(context, level);
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(150);
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 20, 12, 8),
      borderColor: fg.withAlpha(90),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [fg.withAlpha(46), Colors.white.withAlpha(8)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          VerdictRing(level: level, size: 104),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(verdictWord(level, kind), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: fg, letterSpacing: -0.6, height: 1.1)),
              const SizedBox(height: 6),
              Text(verdictLine(level, kind), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.35)),
              const SizedBox(height: 8),
              Text('${tr('Risk {n} / 100', {'n': score})} · ${_kindTitle(kind)}',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: muted, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(tr('Automated opinion, not a guarantee. Not affiliated with any company named.'),
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(130))),
          ),
          ListenButton(key: ObjectKey(result), result: result, color: fg),
        ]),
      ]),
    );
  }
}

/// A glowing ring in the verdict colour that sweeps in, with ✓ / ! / ✕ in the middle.
class VerdictRing extends StatelessWidget {
  const VerdictRing({super.key, required this.level, this.size = 104});
  final String level;
  final double size;
  @override
  Widget build(BuildContext context) {
    final fg = SL.fg(context, level);
    final noMotion = MediaQuery.of(context).disableAnimations;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        key: ValueKey(level),
        tween: Tween<double>(begin: noMotion ? 1.0 : 0.0, end: 1.0),
        duration: const Duration(milliseconds: 750),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => CustomPaint(
          painter: _VerdictRingPainter(v, fg),
          child: Center(
            child: Transform.scale(
              scale: 0.7 + 0.3 * v,
              child: Container(
                width: size * 0.5,
                height: size * 0.5,
                decoration: BoxDecoration(color: fg.withAlpha(40), shape: BoxShape.circle, border: Border.all(color: fg.withAlpha(110), width: 1.5)),
                child: Icon(SL.mark(level), color: fg, size: size * 0.32),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerdictRingPainter extends CustomPainter {
  _VerdictRingPainter(this.v, this.color);
  final double v;
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final stroke = s.width * 0.07;
    canvas.drawCircle(
      c,
      s.width * 0.34,
      Paint()
        ..color = color.withAlpha((70 * v).round())
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.width * 0.14),
    );
    final r = Rect.fromCircle(center: c, radius: s.width / 2 - stroke);
    canvas.drawArc(r, 0, math.pi * 2, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withAlpha(16));
    if (v > 0) {
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * v, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color);
    }
  }

  @override
  bool shouldRepaint(_VerdictRingPainter o) => o.v != v || o.color != color;
}

/// The big buttons under the verdict: Block / Report for a phone number, and 1930 when something looks wrong.
class _Actions extends StatelessWidget {
  const _Actions({required this.level, required this.e164, this.onChanged});
  final String level;
  final String? e164;
  final VoidCallback? onChanged;

  Future<void> _block(BuildContext context, String n) async {
    final ok = await Native.instance.markNumber(n, 'block');
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t save. Please try again.'))));
      return;
    }
    onChanged?.call();
    await showBlockedSheet(context, n);
  }

  @override
  Widget build(BuildContext context) {
    final n = e164;
    final bad = level != 'safe';
    final callHelp = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(foregroundColor: SL.fg(context, 'danger'), side: BorderSide(color: SL.fg(context, 'danger').withAlpha(110))),
      onPressed: () => Native.instance.dial('1930'),
      icon: const Icon(Icons.call_rounded),
      label: Text(tr('Lost money? Call 1930 now')),
    );
    if (n == null) return bad ? callHelp : const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (bad)
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: SL.dangerFill, foregroundColor: Colors.white),
          onPressed: () => _block(context, n),
          icon: const Icon(Icons.block_rounded),
          label: Text(tr('Block this number')),
        ),
      if (bad) const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => reportNumber(context, n, onChanged: onChanged),
            icon: const Icon(Icons.flag_rounded),
            label: Text(tr('Report')),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: bad
              ? OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: SL.fg(context, 'danger')),
                  onPressed: () => Native.instance.dial('1930'),
                  icon: const Icon(Icons.call_rounded),
                  label: const Text('1930'),
                )
              : OutlinedButton.icon(
                  onPressed: () => _block(context, n),
                  icon: const Icon(Icons.block_rounded),
                  label: Text(tr('Block')),
                ),
        ),
      ]),
    ]);
  }
}

/// Top reasons as compact rows; tap a row for the detail. More than three sit behind "Show more".
class _ReasonList extends StatefulWidget {
  const _ReasonList({required this.reasons});
  final List<Map<String, dynamic>> reasons;
  @override
  State<_ReasonList> createState() => _ReasonListState();
}

class _ReasonListState extends State<_ReasonList> {
  bool all = false;
  @override
  Widget build(BuildContext context) {
    final r = widget.reasons;
    final shown = all ? r : r.take(3).toList();
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) Divider(height: 1, indent: 52, color: Colors.white.withAlpha(16)),
          _ReasonRow(shown[i]),
        ],
        if (r.length > 3)
          TextButton(
            onPressed: () => setState(() => all = !all),
            child: Text(all ? tr('Show less') : tr('Show {n} more', {'n': r.length - 3})),
          ),
      ]),
    );
  }
}

class _ReasonRow extends StatefulWidget {
  const _ReasonRow(this.r);
  final Map<String, dynamic> r;
  @override
  State<_ReasonRow> createState() => _ReasonRowState();
}

class _ReasonRowState extends State<_ReasonRow> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final w = ((r['weight'] as num?) ?? 0).toInt();
    final lv = w < 0 ? 'safe' : (w >= 35 ? 'danger' : (w >= 15 ? 'warning' : 'safe'));
    final icon = w < 0 ? Icons.check_circle_rounded : (lv == 'danger' ? Icons.error_rounded : (lv == 'warning' ? Icons.warning_amber_rounded : Icons.info_rounded));
    final fg = SL.fg(context, lv);
    final detail = trReasonDetail(r);
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(140);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: detail.isEmpty ? null : () => setState(() => open = !open),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconTile(icon, color: fg, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(trReasonTitle(r), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, height: 1.3)),
              ),
              if (open && detail.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(detail, style: TextStyle(fontSize: 14, height: 1.4, color: Theme.of(context).colorScheme.onSurface.withAlpha(175))),
                ),
            ]),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(w > 0 ? '+$w' : '$w', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: fg.withAlpha(220))),
          ),
          if (detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: muted)),
        ]),
      ),
    );
  }
}

class _AdviceRow extends StatelessWidget {
  const _AdviceRow(this.n, this.text);
  final int n;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: SL.accent.withAlpha(34), shape: BoxShape.circle),
            child: Text('$n', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: SL.accent)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(trAdvice(text), style: const TextStyle(fontSize: 15, height: 1.4)))),
        ]),
      );
}

class _SenderCard extends StatelessWidget {
  const _SenderCard({required this.sender});
  final Map<String, dynamic> sender;
  @override
  Widget build(BuildContext context) {
    final kind = sender['kind'] as String? ?? 'unknown';
    final lv = kind == 'business' ? 'safe' : 'warning';
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(165);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconTile(_kindIcons[kind] ?? Icons.sms_rounded, color: SL.fg(context, lv)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('From {who}', {'who': sender['raw']}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 2),
              Text(callerLabel(L10n.lang.value, 'sender_$kind') ?? (sender['label'] as String? ?? ''), style: TextStyle(color: muted)),
            ]),
          ),
        ]),
        if (kind == 'business')
          LearnMore(
            child: Text(tr('Registered sender IDs end in -T (transactions), -S (service), -P (promotions) or -G (government).'),
                style: TextStyle(fontSize: 13.5, height: 1.4, color: muted)),
          ),
      ]),
    );
  }
}

/// Who is calling: caller type (person / business / telemarketer / bot / scam); number facts and lookups behind "Learn more".
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
    final lv = _kindLevel(kind ?? 'person');
    final rows = <List<String>>[
      if (d['countryName'] != null) [tr('Country'), '${d['countryName']}  ${d['callingCode'] ?? ''}'],
      if (d['circle'] != null) [tr('State'), '${d['circle']}'],
      if (d['location'] != null) [tr('City'), '${d['location']}'],
      [tr('Type'), numberTypeLabel(L10n.lang.value, '${d['typeLabel'] ?? 'Unknown'}') ?? '${d['typeLabel'] ?? tr('Unknown')}'],
      if (d['carrier'] != null) [tr('Network'), '${d['carrier']}'],
      if (d['series'] != null) [tr('Series'), '${d['series']}'],
      if (d['valid'] == false) [tr('Valid'), tr('No, this number can\'t exist')],
    ];
    final muted = cs.onSurface.withAlpha(160);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconTile(_kindIcons[kind ?? 'unknown'] ?? Icons.phone_rounded, color: SL.fg(context, lv)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d['international'] ?? d['e164'] ?? d['input'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, fontFeatures: [FontFeature.tabularFigures()])),
              if (caller != null)
                Text(callerLabel(L10n.lang.value, '${caller!['kind']}') ?? '${caller!['label']}',
                    style: TextStyle(fontWeight: FontWeight.w700, color: SL.fg(context, _kindLevel(kind ?? 'unknown')))),
            ]),
          ),
        ]),
        if (caller?['detail'] != null) ...[
          const SizedBox(height: 8),
          Text(callerLabel(L10n.lang.value, '${caller!['kind']}_detail') ?? '${caller!['detail']}', style: TextStyle(fontSize: 14, color: muted, height: 1.4)),
        ],
        const SizedBox(height: 4),
        LearnMore(
          label: tr('Number details'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              const SizedBox(height: 12),
              Text(tr('Second Look never uploads anyone\'s contacts, so it doesn\'t keep a names database. On India\'s newer networks, your phone itself may show the caller\'s registered name (CNAP). You can also search the web for reports about this number:'),
                  style: TextStyle(fontSize: 13.5, color: muted, height: 1.4)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _LinkChip(tr('Search the web'), Icons.travel_explore_rounded,
                    () => Native.instance.openUrl('https://www.google.com/search?q=${Uri.encodeQueryComponent('"$e164" scam')}')),
                _LinkChip(tr('Trust'), Icons.verified_rounded, () async {
                  await Native.instance.report(e164, 'safe', tr('Genuine / safe caller'), 'safe');
                  onChanged?.call();
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Marked as trusted on this phone'))));
                }),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Asks why a number is being reported (and whether to warn other users), then saves the report.
Future<void> reportNumber(BuildContext context, String e164, {VoidCallback? onChanged}) async {
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
        avatar: Icon(icon, size: 18, color: SL.accent),
        label: Text(label),
        onPressed: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );
}
