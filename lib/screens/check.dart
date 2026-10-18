import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../community.dart';
import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import 'document_check.dart';
import 'payment_check.dart';
import 'upi_check.dart';
import '../widgets/common.dart';
import '../widgets/verdict.dart';

class CheckScreen extends StatefulWidget {
  const CheckScreen({super.key});
  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  final text = TextEditingController();
  final sender = TextEditingController();
  Map<String, dynamic>? result;
  Map<String, dynamic> status = {};
  bool running = false;

  static const examples = [
    ['Bank KYC SMS', '+919812345678', 'Dear customer, your SBI account will be blocked today. Update PAN now: http://sbi-yono-kyc.top/update'],
    ['Unknown number', '', '+92 300 1234567'],
    ['Fake shop link', '', 'https://www.amaz0n-offers.in/gift'],
    ['Real bank alert', 'VM-SBIINB-T', 'Rs.2,500 debited from A/c XX1234 on 10-Oct. Not you? Call 1800 1234.'],
    ['"Sent by mistake"', '+919812345678', 'Sir I sent Rs 5000 to your number by mistake, please return the amount to rahul.refund@ybl'],
    ['Call forwarding trick', '', 'To upgrade your SIM to 5G, dial *401*9876543210 now'],
  ];

  @override
  void initState() {
    super.initState();
    Native.instance.status().then((s) => mounted ? setState(() => status = s) : null);
  }

  Future<void> run() async {
    final t = text.text.trim();
    if (t.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => running = true);
    try {
      var r = sender.text.trim().isNotEmpty ? await Native.instance.analyzeSms(sender.text.trim(), t) : await Native.instance.analyze(t);
      status = await Native.instance.status(); // the community setting may have changed in Settings
      r = await Community.enrich(r, status);
      if (!mounted) return;
      setState(() => result = r);
    } on PlatformException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? tr('The check failed'))));
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  Future<void> paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (mounted && d?.text != null) setState(() => text.text = d!.text!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final web = status['platform'] == 'web';
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(tr('Check something')), actions: const [LanguageButton()]),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        Panel(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.content_paste_search_rounded, color: SL.accent, size: 22),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('Paste & check'), style: Theme.of(context).textTheme.titleMedium)),
              Icon(web ? Icons.laptop_rounded : Icons.phone_android_rounded, size: 16, color: cs.onSurface.withAlpha(130)),
              const SizedBox(width: 4),
              Text(web ? tr('In this browser') : tr('On this phone'), style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(150))),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: text,
              minLines: 3,
              maxLines: 10,
              maxLength: 10000,
              decoration: InputDecoration(
                hintText: tr('Link, SMS, phone number or UPI ID'),
                suffixIcon: IconButton(tooltip: tr('Paste'), onPressed: paste, icon: const Icon(Icons.content_paste_rounded)),
              ),
            ),
            LearnMore(
              label: tr('Add who sent it (optional)'),
              initiallyOpen: sender.text.isNotEmpty,
              child: TextField(
                controller: sender,
                decoration: InputDecoration(
                  labelText: tr('Who sent it? (optional)'),
                  hintText: tr('e.g. VM-SBIINB-T or +91 98xxx xxx10'),
                  prefixIcon: const Icon(Icons.person_search_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: running ? null : run,
              icon: running ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.shield_rounded),
              label: Text(running ? tr('Checking…') : tr('Check it')),
            ),
          ]),
        ),
        if (result != null) ...[
          const SizedBox(height: 18),
          VerdictView(result: result!, trustedName: status['trustedName'] as String?, trustedNumber: status['trustedNumber'] as String?, onChanged: run),
        ],
        SectionLabel(tr('Try an example'), icon: Icons.science_rounded),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in examples)
            ActionChip(
              label: Text(tr(e[0])),
              onPressed: () {
                sender.text = e[1];
                text.text = e[2];
                run();
              },
            ),
        ]),
        SectionLabel(tr('More checks'), icon: Icons.grid_view_rounded),
        // Three tools side by side; equal heights, and the text wraps instead of overflowing on narrow phones.
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: _Tool(
                icon: Icons.receipt_long_rounded,
                title: tr('Payment proof'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaymentCheckScreen())),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Tool(
                icon: Icons.qr_code_scanner_rounded,
                title: tr('UPI or QR'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UpiCheckScreen())),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Tool(
                icon: Icons.badge_rounded,
                title: tr('Document'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DocumentCheckScreen())),
              ),
            ),
          ]),
        ),
        if (result == null) ...[
          SectionLabel(tr('Good to know'), icon: Icons.lightbulb_rounded),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Real bank SMS come from names like VM-SBIINB-T, not from a 10-digit number.'), style: const TextStyle(height: 1.45, fontWeight: FontWeight.w600)),
              LearnMore(
                child: Text(
                  tr('Real bank and company SMS in India come from sender names like VM-SBIINB-T, never from a 10-digit mobile number. The last letter tells you the type: T for transactions and OTPs, S for service, P for promotions, G for government.'),
                  style: TextStyle(height: 1.45, color: cs.onSurface.withAlpha(180)),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.title, required this.onTap});
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Panel(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
        child: Column(children: [
          IconTile(icon, color: SL.accent, size: 40),
          const SizedBox(height: 8),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, height: 1.2)),
        ]),
      );
}
