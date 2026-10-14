import 'package:flutter/material.dart';

import '../cloud.dart';
import '../i18n/i18n.dart';
import '../monetize/monetize.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Second Look Plus: unlimited deep checks, no ads, use on more devices.
/// Basic protection stays free for everyone.
class PlusScreen extends StatefulWidget {
  const PlusScreen({super.key});
  @override
  State<PlusScreen> createState() => _PlusScreenState();
}

class _PlusScreenState extends State<PlusScreen> {
  Map<String, dynamic>? quota;
  List<PlusProduct> products = [];
  String? message, linkCode;
  bool loading = true, busy = false;
  final codeCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    Monetize.listen((status, msg) {
      if (!mounted) return;
      setState(() {
        message = msg;
        busy = status == 'pending';
      });
      if (status == 'active') _load();
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final q = Cloud.configured ? await Cloud.instance.quota() : null;
      final p = Monetize.storeSupported ? await Monetize.products() : <PlusProduct>[];
      if (!mounted) return;
      setState(() {
        quota = q;
        products = p;
      });
    } catch (e) {
      if (mounted) setState(() => message = tr('Couldn\'t reach Second Look right now. Check your internet.'));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _buy(String id) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await Monetize.buy(id);
    } catch (e) {
      if (mounted) setState(() => message = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _getCode() async {
    try {
      final c = await Cloud.instance.linkCode();
      if (mounted) setState(() => linkCode = c);
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> _claim() async {
    try {
      final q = await Cloud.instance.claimLink(codeCtl.text);
      if (!mounted) return;
      setState(() {
        quota = q;
        message = tr('This device now has Plus.');
      });
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  @override
  void dispose() {
    Monetize.unlisten();
    codeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final plus = quota?['plus'] == true;
    final until = (quota?['plusUntil'] as num?)?.toDouble() ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Second Look Plus')),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        Panel(
          padding: const EdgeInsets.all(22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(color: SL.amber.withAlpha(50), borderRadius: BorderRadius.circular(18)),
              child: const Icon(Icons.workspace_premium_rounded, size: 34, color: Color(0xFF9A5B00)),
            ),
            const SizedBox(height: 14),
            Text(plus ? tr('Plus is active') : tr('More protection, no ads'), style: Theme.of(context).textTheme.headlineMedium),
            if (plus && until > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Renews or ends on {date}', {'date': _date(until)}), style: TextStyle(color: cs.onSurface.withAlpha(170))),
              ),
            const SizedBox(height: 16),
            _Benefit(Icons.travel_explore_rounded, tr('Unlimited deep checks'), tr('Check any link against Google Web Risk and phishing lists, as often as you like.')),
            _Benefit(Icons.block_rounded, tr('No ads, ever'), tr('Never asked to watch an ad.')),
            _Benefit(Icons.devices_rounded, tr('Use it on 3 more devices'), tr('Link your laptop or a family member\'s phone with a code.')),
            _Benefit(Icons.volunteer_activism_rounded, tr('Keep basic protection free'), tr('Your plan pays for free scam protection for everyone else.')),
          ]),
        ),
        SectionLabel(tr('Always free for everyone')),
        Panel(
          child: Text(
            tr('SMS Shield, Call Shield, the basic check of any link, message or number, and the "Being scammed?" help stay free, with no ads in front of them.'),
            style: TextStyle(color: cs.onSurface.withAlpha(180), height: 1.45),
          ),
        ),
        if (!plus && Monetize.storeSupported) ...[
          SectionLabel(tr('Choose a plan')),
          if (loading)
            const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
          else if (products.isEmpty)
            Panel(child: Text(tr('Plans aren\'t available in the store yet.')))
          else
            for (final p in products) ...[
              Panel(
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.id.endsWith('yearly') ? tr('Yearly') : tr('Monthly'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      Text(p.price, style: TextStyle(color: cs.onSurface.withAlpha(170))),
                    ]),
                  ),
                  FilledButton(onPressed: busy ? null : () => _buy(p.id), child: Text(tr('Subscribe'))),
                ]),
              ),
              const SizedBox(height: 10),
            ],
          TextButton(onPressed: busy ? null : Monetize.restore, child: Text(tr('Restore purchases'))),
          Text(tr('Cancel any time in Google Play or App Store subscriptions.'), style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(140))),
        ],
        SectionLabel(tr('Link another device')),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (plus && Monetize.storeSupported) ...[
              Text(tr('Get a one-time code, then enter it in Second Look on your laptop or another phone. It works for 10 minutes.')),
              const SizedBox(height: 12),
              if (linkCode != null)
                SelectableText(linkCode!, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 4))
              else
                OutlinedButton.icon(onPressed: _getCode, icon: const Icon(Icons.key_rounded), label: Text(tr('Get a link code'))),
            ] else ...[
              Text(Monetize.storeSupported
                  ? tr('Someone in your family has Plus? Ask them for a link code from their Plus screen.')
                  : tr('Plus is bought in the Second Look phone app. Open Plus there, tap "Get a link code" and type it here.')),
              const SizedBox(height: 12),
              TextField(controller: codeCtl, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: tr('Link code'), hintText: 'ABCD-EFGH')),
              const SizedBox(height: 10),
              FilledButton(onPressed: _claim, child: Text(tr('Link this device'))),
            ],
          ]),
        ),
        if (message != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(message!, style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  static String _date(double secs) {
    final d = DateTime.fromMillisecondsSinceEpoch((secs * 1000).round());
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${tr(m[d.month - 1])} ${d.year}';
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit(this.icon, this.title, this.text);
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
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
