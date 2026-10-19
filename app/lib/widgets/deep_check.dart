import 'dart:async';

import 'package:flutter/material.dart';

import '../cloud.dart';
import '../i18n/i18n.dart';
import '../monetize/monetize.dart';
import '../native.dart';
import '../theme.dart';
import 'common.dart';

/// Optional online "deep check" of links, shown under a verdict.
/// The basic check above it is always free and never waits for this.
class DeepCheckCard extends StatefulWidget {
  const DeepCheckCard({super.key, required this.urls});
  final List<String> urls;
  @override
  State<DeepCheckCard> createState() => _DeepCheckCardState();
}

class _DeepCheckCardState extends State<DeepCheckCard> {
  Map<String, dynamic>? quota;
  Map<String, dynamic>? result;
  String? error; // English; shown with tr() so it follows the language
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _loadQuota();
  }

  Future<void> _loadQuota() async {
    try {
      final q = await Cloud.instance.quota();
      if (mounted) setState(() => quota = q);
    } catch (_) {
      // Offline: the button still works and reports the problem when tapped.
    }
  }

  Future<void> run() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    var offer = false;
    try {
      final r = await Cloud.instance.deepCheck(widget.urls);
      if (!mounted) return;
      setState(() {
        result = r;
        quota = (r['quota'] as Map?)?.cast<String, dynamic>() ?? quota;
      });
    } on CloudError catch (e) {
      if (!mounted) return;
      if (e.needsAd) {
        setState(() => quota = (e.detail as Map).cast<String, dynamic>());
        offer = true;
      } else {
        setState(() => error = e.message);
      }
    } catch (_) {
      if (mounted) setState(() => error = 'No internet connection. The check above still applies.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    // Offered after `busy` is cleared, so a retry started from the sheet (after an ad) isn't blocked or un-busied.
    if (offer && mounted) await _offerMore();
  }

  /// Today's 3 free deep checks are used: on a phone, a short ad adds one more. The basic check is always free.
  Future<void> _offerMore() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('You\'ve used today\'s 3 free deep checks'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(tr('The basic check above is always free and unlimited. Deep checks reset at midnight.'),
                style: TextStyle(color: Theme.of(c).colorScheme.onSurface.withAlpha(170))),
            const SizedBox(height: 18),
            if (Monetize.adsSupported)
              FilledButton.icon(
                onPressed: () => Navigator.pop(c, 'ad'),
                icon: const Icon(Icons.play_circle_outline_rounded),
                label: Text(tr('Watch a short ad for 1 more deep check')),
              )
            else
              OutlinedButton(onPressed: () => Navigator.pop(c), child: Text(tr('OK'))),
          ]),
        ),
      ),
    );
    if (!mounted || choice != 'ad') return;
    // Rewarded ad: the server adds the credit once Google confirms the reward.
    final watched = await Monetize.showRewardedAd(await Cloud.instance.installId());
    if (!mounted) return;
    if (!watched) {
      setState(() => error = 'The ad didn\'t finish, so no deep check was added.');
      return;
    }
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        final q = await Cloud.instance.quota();
        if (!mounted) return;
        setState(() => quota = q);
        if ((q['credits'] as num? ?? 0) > 0 || (q['freeLeft'] as num? ?? 0) > 0) {
          unawaited(run());
          return;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => error = 'Thanks! Your extra check will appear in a moment. Tap Deep check again.');
  }

  String _quotaText() {
    final q = quota;
    if (q == null) return tr('Checks the link against Google Web Risk and known phishing lists.');
    final free = q['freeLeft'] ?? 0, credits = q['credits'] ?? 0;
    final left = tr('{free} of {total} free left today', {'free': free, 'total': q['freePerDay'] ?? 3});
    return credits is num && credits > 0 ? '$left · ${tr('{n} extra', {'n': credits})}' : left;
  }

  @override
  Widget build(BuildContext context) {
    if (!Cloud.configured || widget.urls.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final res = (result?['results'] as List?)?.cast<Map>() ?? [];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.travel_explore_rounded, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(tr('Deep check online'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          ]),
          const SizedBox(height: 4),
          Text(_quotaText(), style: TextStyle(fontSize: 13.5, color: cs.onSurface.withAlpha(160))),
          const SizedBox(height: 4),
          Text(
              tr('Only the link is sent, never your message or number. Online lists can be wrong or miss new scam sites; '
                  'no service can guarantee its information is complete and error-free.'),
              style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(130))),
          if (result == null) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: busy ? null : run,
              icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.shield_moon_rounded),
              label: Text(busy
                  ? tr('Checking…')
                  : widget.urls.length == 1
                      ? tr('Deep check this link')
                      : tr('Deep check {n} links', {'n': widget.urls.length})),
            ),
          ],
          if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(tr(error!), style: TextStyle(color: SL.fg(context, 'warning')))),
          for (final r in res) ...[
            const Divider(height: 24),
            _ResultRow(r.cast<String, dynamic>()),
          ],
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(tr('Checked with: {list}', {'list': ((result!['checkedWith'] as List?) ?? const []).join(', ')}),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(130))),
            ),
        ]),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow(this.r);
  final Map<String, dynamic> r;
  @override
  Widget build(BuildContext context) {
    final level = ((r['level'] as Map?)?['key'] as String?) ?? 'safe';
    final sources = ((r['sources'] as List?) ?? []).cast<Map>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(SL.icon(level), color: SL.fg(context, level), size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text('${r['host'] ?? r['url']}', style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
        Pill(level == 'danger' ? tr('Likely unsafe') : level == 'warning' ? tr('Possibly unsafe') : tr('Not listed'), fg: SL.fg(context, level), bg: SL.bg(context, level)),
      ]),
      for (final s in sources)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 28),
          child: Text('${s['source']}: ${s['detail']}', style: const TextStyle(fontSize: 13.5)),
        ),
      // Required by Google's Web Risk terms when a warning is based on Google's data.
      if (sources.any((s) => s['advisory'] == 'google'))
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Wrap(children: [
            TextButton(
              onPressed: () => Native.instance.openUrl('https://docs.cloud.google.com/web-risk/docs/advisory'),
              child: Text(tr('Advisory provided by Google')),
            ),
            TextButton(
              onPressed: () => Native.instance.openUrl('https://www.antiphishing.org'),
              child: Text(tr('Learn about phishing')),
            ),
          ]),
        ),
      if (sources.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 28),
          child: Text(tr('Not on any blocklist we checked. New scam sites appear daily, so still be careful.'),
              style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(160))),
        ),
    ]);
  }
}
