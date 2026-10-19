import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../cloud.dart';
import '../i18n/i18n.dart';
import '../i18n/reasons.dart';
import '../monetize/ad_rules.dart';
import '../native.dart';
import '../perf.dart';
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

/// One check at a glance: a glowing verdict mark, the verdict in two words and one plain sentence, risk and
/// community chips, up to three reasons, then the actions (Block / Report / Call 1930). Community reports,
/// the online Deep check and the full details sit below.
class VerdictView extends StatelessWidget {
  const VerdictView({super.key, required this.result, this.trustedName, this.trustedNumber, this.onChanged, this.onBack, this.title});
  final Map<String, dynamic> result;
  final String? trustedName, trustedNumber;
  final VoidCallback? onChanged;

  /// Set on the full-page result: shows the back button and lets the glow run to the top of the screen.
  final VoidCallback? onBack;

  /// A short caption at the top of the full-page result (English; shown with tr()).
  final String? title;

  @override
  Widget build(BuildContext context) {
    final level = '${(result['level'] as Map?)?['key'] ?? 'safe'}';
    final kind = result['kind'] as String?;
    final label = trLevel((result['level'] as Map?) ?? const {'key': 'safe'}, kind: kind);
    final score = ((result['score'] as num?) ?? 0).toInt();
    final info = (result['info'] as Map?)?.cast<String, dynamic>() ?? {};
    final reasons = [
      for (final r in (result['reasons'] as List? ?? []).whereType<Map>())
        if (((r['weight'] as num?) ?? 0) != 0) r.cast<String, dynamic>(),
    ];
    final advice = (result['advice'] as List? ?? []).map((e) => '$e').toList();
    final number = (info['numberDetails'] as Map?)?.cast<String, dynamic>();
    final caller = (info['caller'] as Map?)?.cast<String, dynamic>();
    final sender = (info['sender'] as Map?)?.cast<String, dynamic>();
    final senderNumber = (sender?['number'] as Map?)?.cast<String, dynamic>();
    final phones = (info['phones'] as List? ?? []).whereType<Map>().toList();
    final phoneDetails = number ?? senderNumber;
    final e164 = '${phoneDetails?['e164'] ?? ''}';
    final hasNumber = e164.replaceAll(RegExp(r'\D'), '').length >= 7;
    final senderRaw = '${sender?['raw'] ?? ''}'.trim();
    final community = info['community'] is Map ? (info['community'] as Map).cast<String, dynamic>() : null;
    final reported = (community?['total'] as num?)?.toInt() ?? 0;
    final full = onBack != null;
    final hasDetails = advice.isNotEmpty || caller != null || number != null || sender != null || phones.isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _VerdictHero(
        result: result,
        level: level,
        kind: kind,
        score: score,
        reported: reported,
        sentence: _sentence(level, kind, reasons),
        caption: title != null ? tr(title!) : _kindTitle(kind),
        onBack: onBack,
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: full ? 20 : 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: full ? 4 : 18),
          Text(tr('Why').toUpperCase(), style: SL.h(15, color: SL.textSecondary, weight: FontWeight.w600, spacing: 0.6)),
          const SizedBox(height: 10),
          if (reasons.isEmpty)
            _ReasonBox(
              icon: Icons.check_circle_outline_rounded,
              color: SL.safeD,
              title: tr('None of the known scam patterns matched.'),
            )
          else
            _ReasonList(reasons: reasons),
          const SizedBox(height: 8),
          _Actions(
            level: level,
            kind: kind,
            e164: hasNumber ? e164 : null,
            blockTarget: hasNumber ? e164 : (senderRaw.isNotEmpty ? senderRaw : null),
            fromSender: sender != null,
            onChanged: onChanged,
          ),
          const SizedBox(height: 14),
          Text(tr('Automated opinion, not a guarantee. Not affiliated with any company named.'),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: SL.textMuted, height: 1.4)),
          if (community != null) ...[
            const SizedBox(height: 18),
            CommunityCard(key: ValueKey('${community['number']}'), summary: community),
          ],
          DeepCheckCard(key: ValueKey(Cloud.linksIn(result).join('|')), urls: Cloud.linksIn(result)),
          if (hasDetails) ...[
            const SizedBox(height: 8),
            LearnMore(
              label: tr('More details'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (advice.isNotEmpty) ...[
                  SectionLabel(tr('What to do now')),
                  Panel(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (var i = 0; i < advice.length; i++) _AdviceRow(i + 1, advice[i]),
                    ]),
                  ),
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
              ]),
            ),
          ],
          if (level != 'safe' && (trustedNumber ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            SoftButton(
              icon: Icons.family_restroom_rounded,
              onPressed: () => Native.instance.smsTo(trustedNumber!,
                  tr('Second Look flagged something on my phone as "{label}". Can you check it with me before I do anything?', {'label': label.toLowerCase()})),
              label: tr('Ask {name} to check', {'name': trustedName?.isNotEmpty == true ? trustedName : tr('my trusted person')}),
            ),
          ],
        ]),
      ),
    ]);
  }
}

/// The one sentence under the verdict: the main reason in plain words when it's short, otherwise what to do.
/// Documents and payment screenshots always get their own fixed wording.
String _sentence(String level, String? kind, List<Map<String, dynamic>> reasons) {
  if (kind == 'document' || kind == 'payment' || level == 'safe') return verdictLine(level, kind);
  Map<String, dynamic>? top;
  for (final r in reasons) {
    final w = ((r['weight'] as num?) ?? 0).toInt();
    if (w > 0 && (top == null || w > ((top['weight'] as num?) ?? 0).toInt())) top = r;
  }
  if (top != null) {
    final d = trReasonDetail(top).trim();
    if (d.isNotEmpty && d.length <= 160) return d;
  }
  return verdictLine(level, kind);
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

/// The top of a result: a radial glow in the verdict colour, back + Listen, the 132 px mark, the verdict word
/// (Sora 36), one sentence and the chips.
class _VerdictHero extends StatelessWidget {
  const _VerdictHero({
    required this.result,
    required this.level,
    required this.kind,
    required this.score,
    required this.reported,
    required this.sentence,
    required this.caption,
    this.onBack,
  });
  final Map<String, dynamic> result;
  final String level;
  final String? kind;
  final int score, reported;
  final String sentence, caption;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final fg = SL.fgOf(level);
    final full = onBack != null;
    final chipText = SL.pale(level);
    final top = Row(children: [
      if (full) BackCircle(onPressed: onBack, border: const Color(0x2EFFFFFF)) else const SizedBox(width: 4),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(caption,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: SL.textSecondary)),
        ),
      ),
      ListenButton(key: ObjectKey(result), result: result),
    ]);
    final body = Column(children: [
      top,
      const SizedBox(height: 12),
      _VerdictMark(level: level),
      const SizedBox(height: 16),
      Text(verdictWord(level, kind), textAlign: TextAlign.center, style: SL.h(36, color: SL.pale(level), height: 1.12)),
      const SizedBox(height: 6),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 310),
        child: Text(sentence, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, height: 1.45, color: Color(0xFFE2E8F0), fontWeight: FontWeight.w500)),
      ),
      const SizedBox(height: 14),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        Pill(tr('Risk {n} / 100', {'n': score}), fg: fg, bg: fg.withAlpha(36), textColor: chipText),
        if (reported > 0) Pill(tr('Reported by {n} people', {'n': reported}), fg: fg, bg: fg.withAlpha(36), textColor: chipText),
      ]),
    ]);
    final glow = RadialGradient(
      center: Alignment.topCenter,
      radius: 1.15,
      colors: [fg.withAlpha(71), fg.withAlpha(0)],
      stops: const [0.0, 0.7],
    );
    if (full) {
      return Container(
        padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 14, 20, 20),
        decoration: BoxDecoration(gradient: glow),
        child: body,
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      decoration: BoxDecoration(
        gradient: glow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: fg.withAlpha(56)),
      ),
      child: body,
    );
  }
}

/// ✕ / ! / ✓ in a 116 px circle with a glow, and a ring that keeps expanding outwards (1.8 s).
/// Holds still when the phone asks for reduced motion.
class _VerdictMark extends StatefulWidget {
  const _VerdictMark({required this.level});
  final String level;
  @override
  State<_VerdictMark> createState() => _VerdictMarkState();
}

class _VerdictMarkState extends State<_VerdictMark> with SingleTickerProviderStateMixin, LoopMotion<_VerdictMark> {
  late final AnimationController ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  bool get still => motionStill;

  /// No ring animation in the battery saver look or with reduced motion; paused while the app is in the background.
  @override
  void applyMotion({required bool still, required bool run}) {
    if (still) {
      ring.stop();
      ring.value = 0.25;
    } else if (run) {
      if (!ring.isAnimating) ring.repeat();
    } else {
      ring.stop();
    }
  }

  @override
  void dispose() {
    ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = SL.fgOf(widget.level);
    final centre = Container(
      width: 116,
      height: 116,
      decoration: BoxDecoration(
        color: SL.deep(widget.level),
        shape: BoxShape.circle,
        border: Border.all(color: fg, width: 3),
        boxShadow: [BoxShadow(color: fg.withAlpha(128), blurRadius: 50)],
      ),
      child: Icon(SL.mark(widget.level), size: 56, color: fg),
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: 132,
        height: 132,
        child: Stack(alignment: Alignment.center, children: [
          AnimatedBuilder(
            animation: ring,
            builder: (context, _) {
              final t = Curves.easeOut.transform(ring.value);
              final op = 0.8 * (1 - t);
              return Transform.scale(
                scale: 0.9 + 0.45 * t,
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: fg.withAlpha((153 * op).round()), width: 2)),
                ),
              );
            },
          ),
          TweenAnimationBuilder<double>(
            key: ValueKey(widget.level),
            tween: Tween<double>(begin: still ? 1.0 : 0.8, end: 1.0),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutBack,
            builder: (context, v, child) => Transform.scale(scale: v, child: child),
            child: centre,
          ),
        ]),
      ),
    );
  }
}

/// The main action, full width, then Report and Call 1930.
/// Block for anything with a sender (SMS or number); otherwise the most useful "don't" for that kind of check.
class _Actions extends StatelessWidget {
  const _Actions({required this.level, required this.kind, required this.e164, required this.blockTarget, required this.fromSender, this.onChanged});
  final String level;
  final String? kind;
  final String? e164; // a real phone number (for reports)
  final String? blockTarget; // phone number or SMS sender ID
  final bool fromSender;
  final VoidCallback? onChanged;

  Future<void> _block(BuildContext context, String n) async {
    AdRules.acted(); // someone acting on a result is never interrupted by an ad afterwards
    final ok = await Native.instance.markNumber(n, 'block');
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t save. Please try again.'))));
      return;
    }
    onChanged?.call();
    await showBlockedSheet(context, n);
  }

  String _dontLabel() {
    switch (kind) {
      case 'payment':
      case 'upi':
      case 'document':
        return tr('Don\'t pay');
      case 'link':
        return tr('Don\'t open the link');
      default:
        return tr('Don\'t reply or share codes');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bad = level != 'safe';
    final n = e164;
    final b = blockTarget;
    if (!bad && n == null) return const SizedBox(height: 4);
    final children = <Widget>[];
    if (bad) {
      children.add(GlowButton(
        label: b != null ? (fromSender ? tr('Block sender') : tr('Block this number')) : _dontLabel(),
        color: SL.fgOf(level),
        textColor: SL.on(level),
        height: 60,
        radius: 18,
        fontSize: 17,
        glow: false,
        onPressed: b != null ? () => _block(context, b) : () => Navigator.of(context).maybePop(),
      ));
      children.add(const SizedBox(height: 10));
    }
    children.add(Row(children: [
      Expanded(
        child: SoftButton(
          label: tr('Report'),
          onPressed: () {
            AdRules.acted();
            if (n != null) {
              reportNumber(context, n, onChanged: onChanged);
            } else {
              Native.instance.openUrl('https://sancharsaathi.gov.in');
            }
          },
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: bad
            ? SoftButton(
                label: tr('Call 1930'),
                onPressed: () {
                  AdRules.acted();
                  Native.instance.dial('1930');
                })
            : SoftButton(label: tr('Block'), onPressed: () => _block(context, n!)),
      ),
    ]));
    return Padding(padding: const EdgeInsets.only(top: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children));
  }
}

/// Up to three reasons as separate rows; tap one for the detail. More sit behind "Show n more".
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final x in shown) _ReasonRow(x),
      if (r.length > 3)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => all = !all),
            child: Text(all ? tr('Show less') : tr('Show {n} more', {'n': r.length - 3})),
          ),
        ),
    ]);
  }
}

/// An icon that fits the reason (link, time pressure, codes, money, calls, apps), coloured by how much it weighs.
IconData _reasonIcon(Map<String, dynamic> r, int w, String lv) {
  if (w < 0) return Icons.check_circle_outline_rounded;
  final k = '${r['id'] ?? ''} ${r['title'] ?? ''}'.toLowerCase();
  if (RegExp(r'link|url|domain|site|web|http').hasMatch(k)) return Icons.link_rounded;
  if (RegExp(r'urgen|today|hour|immediat|deadline|expire|time').hasMatch(k)) return Icons.schedule_rounded;
  if (RegExp(r'otp|pin|cvv|password|kyc|bank|card').hasMatch(k)) return Icons.lock_outline_rounded;
  if (RegExp(r'upi|pay|money|refund|prize|lottery|reward|loan|₹').hasMatch(k)) return Icons.currency_rupee_rounded;
  if (RegExp(r'call|number|phone|dial|sender|caller').hasMatch(k)) return Icons.call_outlined;
  if (RegExp(r'app|apk|install|screen|remote').hasMatch(k)) return Icons.install_mobile_rounded;
  return lv == 'danger' ? Icons.error_outline_rounded : Icons.info_outline_rounded;
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
    final lv = w < 0 ? 'safe' : (w >= 35 ? 'danger' : 'warning');
    final color = w > 0 && w < 15 ? SL.accent : SL.fgOf(lv);
    final detail = trReasonDetail(r);
    return _ReasonBox(
      icon: _reasonIcon(r, w, lv),
      color: color,
      title: trReasonTitle(r),
      detail: open && detail.isNotEmpty ? detail : null,
      expandable: detail.isNotEmpty,
      open: open,
      onTap: detail.isEmpty ? null : () => setState(() => open = !open),
    );
  }
}

/// One reason row: a 22 px icon and a short line on a faint card; the detail opens underneath.
class _ReasonBox extends StatelessWidget {
  const _ReasonBox({required this.icon, required this.color, required this.title, this.detail, this.expandable = false, this.open = false, this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final String? detail;
  final bool expandable, open;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(16);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: SL.glass,
        shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: SL.hairline)),
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, height: 1.35, color: SL.text)),
                  if (detail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(detail!, style: const TextStyle(fontSize: 14, height: 1.4, color: SL.textSoft)),
                    ),
                ]),
              ),
              if (expandable) Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: SL.textMuted),
            ]),
          ),
        ),
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
