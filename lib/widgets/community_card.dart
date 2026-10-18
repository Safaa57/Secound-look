import 'package:flutter/material.dart';

import '../cloud.dart';
import '../i18n/i18n.dart';
import '../i18n/reasons.dart';
import '../theme.dart';
import 'common.dart';

/// What other Second Look users reported about a number, with their notes.
class CommunityCard extends StatefulWidget {
  const CommunityCard({super.key, required this.summary});
  final Map<String, dynamic> summary;
  @override
  State<CommunityCard> createState() => _CommunityCardState();
}

class _CommunityCardState extends State<CommunityCard> {
  late Map<String, dynamic> c = widget.summary;
  final _flagged = <String>{};

  @override
  void didUpdateWidget(CommunityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.summary, widget.summary)) c = widget.summary; // the number was checked again
  }

  String _ago(num at) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((at * 1000).round()));
    if (d.inDays >= 30) return tr('{n} mo ago', {'n': d.inDays ~/ 30});
    if (d.inDays >= 1) return tr('{n} d ago', {'n': d.inDays});
    if (d.inHours >= 1) return tr('{n} h ago', {'n': d.inHours});
    return tr('{n} min ago', {'n': d.inMinutes.clamp(1, 59)});
  }

  Future<void> _flag(String id) async {
    try {
      await Cloud.instance.communityFlag('${c['number']}', id);
      if (!mounted) return;
      setState(() => _flagged.add(id));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Thanks. Notes flagged by several people are hidden.'))));
    } catch (_) {}
  }

  Future<void> _dispute() async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(tr('Is this your number?'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(tr('Your dispute is shown next to the reports, so others know the reports may be wrong.')),
          ),
          for (final r in [
            ['mine_not_scam', tr('This is my personal number and I\'m not a scammer')],
            ['business', tr('This is a genuine business line')],
            ['new_owner', tr('I got this number recently; the reports are about someone before me')],
          ])
            ListTile(title: Text(r[1]), onTap: () => Navigator.pop(s, r[0])),
        ]),
      ),
    );
    if (reason == null) return;
    try {
      final n = await Cloud.instance.communityDispute('${c['number']}', reason);
      if (mounted) setState(() => c = n);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = (c['total'] as num?)?.toInt() ?? 0;
    final scam = (c['scam'] as num?)?.toInt() ?? 0;
    final spam = (c['spam'] as num?)?.toInt() ?? 0;
    final safe = (c['safe'] as num?)?.toInt() ?? 0;
    final shown = c['shown'] == true;
    final labels = (c['typeLabels'] as Map?)?.cast<String, dynamic>() ?? {};
    final by = ((c['byType'] as Map?)?.cast<String, dynamic>() ?? {}).entries.toList()
      ..sort((a, b) => (b.value as num).compareTo(a.value as num));
    final comments = ((c['comments'] as List?) ?? []).cast<Map>().where((m) => !_flagged.contains(m['id'])).toList();
    final level = scam >= 3 ? 'danger' : (scam + spam) > 0 ? 'warning' : 'safe';

    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.groups_rounded, color: SL.fg(context, level)),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('Community reports'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
        ]),
        const SizedBox(height: 10),
        if (total == 0)
          Text(tr('No one has reported this number yet.'), style: TextStyle(color: cs.onSurface.withAlpha(170)))
        else if (!shown)
          Text(
              total == 1
                  ? tr('1 person has reported this number. Reports are shown once {min} or more people agree.', {'min': c['minShow'] ?? 3})
                  : tr('{n} people have reported this number. Reports are shown once {min} or more people agree.', {'n': total, 'min': c['minShow'] ?? 3}),
              style: TextStyle(color: cs.onSurface.withAlpha(170)))
        else ...[
          if (scam > 0)
            Text(scam == 1 ? tr('Reported as fraud by 1 person') : tr('Reported as fraud by {n} people', {'n': scam}),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: SL.fg(context, 'danger'))),
          if (spam > 0) Text(tr('Reported as spam by {n}', {'n': spam}), style: TextStyle(fontWeight: FontWeight.w700, color: SL.fg(context, 'warning'))),
          if (safe > 0) Text(tr('{n} marked it as genuine', {'n': safe}), style: TextStyle(color: cs.onSurface.withAlpha(170))),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in by.take(4))
              Pill('${reportTypeLabel(L10n.lang.value, e.key) ?? labels[e.key] ?? e.key} · ${e.value}', fg: SL.fg(context, e.key == 'safe' ? 'safe' : e.key == 'spam' ? 'warning' : 'danger'),
                  bg: SL.bg(context, e.key == 'safe' ? 'safe' : e.key == 'spam' ? 'warning' : 'danger')),
          ]),
          if (comments.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(tr('What people said'), style: Theme.of(context).textTheme.titleSmall),
            for (final m in comments)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.format_quote_rounded, size: 20, color: cs.onSurface.withAlpha(120)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if ((m['note'] ?? '').toString().isNotEmpty) Text('${m['note']}', style: const TextStyle(height: 1.4)),
                      if ((m['claimed'] ?? '').toString().isNotEmpty)
                        Text(tr('Said they were: {name}', {'name': m['claimed']}), style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(170))),
                      Text('${reportTypeLabel(L10n.lang.value, '${m['type']}') ?? m['typeLabel'] ?? m['type']} · ${_ago((m['at'] as num?) ?? 0)}',
                          style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(140))),
                    ]),
                  ),
                  IconButton(
                    tooltip: tr('Flag this note'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.outlined_flag_rounded, size: 20),
                    onPressed: () => _flag('${m['id']}'),
                  ),
                ]),
              ),
          ],
          if (((c['disputes'] as num?) ?? 0) > 0)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.outlineVariant)),
              child: Text(c['disputes'] == 1
                  ? tr('Disputed: 1 person says this is their number and the reports are wrong.')
                  : tr('Disputed: {n} people say this is their number and the reports are wrong.', {'n': c['disputes']})),
            ),
        ],
        const SizedBox(height: 10),
        Text(tr('Reports come from Second Look users and aren\'t verified. Notes are shown without names, and phone numbers and links in them are removed.'),
            style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(140))),
        if (shown) Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _dispute, child: Text(tr('This is my number')))),
      ]),
    );
  }
}
