import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../community.dart';
import '../i18n/i18n.dart';
import '../native.dart';
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
    if (d?.text != null) setState(() => text.text = d!.text!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Check something')), actions: const [LanguageButton()]),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        Row(children: [
          Expanded(
            child: _Tool(
              icon: Icons.receipt_long_rounded,
              title: tr('Payment screenshot'),
              sub: tr('Spot fake "paid" proofs'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaymentCheckScreen())),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Tool(
              icon: Icons.qr_code_scanner_rounded,
              title: tr('UPI ID or QR'),
              sub: tr('Check before you pay'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UpiCheckScreen())),
            ),
          ),
        ]),
        const SizedBox(height: 18),
        Text(status['platform'] == 'web'
                ? tr('Or paste a link, a whole message, a phone number or a UPI ID. The check runs in your browser.')
                : tr('Or paste a link, a whole message, a phone number or a UPI ID. The check runs on your phone.'),
            style: TextStyle(color: cs.onSurface.withAlpha(170))),
        const SizedBox(height: 14),
        TextField(
          controller: text,
          minLines: 4,
          maxLines: 10,
          maxLength: 10000,
          decoration: InputDecoration(
            hintText: tr('e.g. Your account will be blocked, update KYC: http://…   or   +92 300 1234567'),
            suffixIcon: IconButton(tooltip: tr('Paste'), onPressed: paste, icon: const Icon(Icons.content_paste_rounded)),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: sender,
          decoration: InputDecoration(
            labelText: tr('Who sent it? (optional)'),
            hintText: tr('e.g. VM-SBIINB-T or +91 98xxx xxx10'),
            prefixIcon: const Icon(Icons.person_search_rounded),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: running ? null : run, icon: const Icon(Icons.shield_rounded), label: Text(running ? tr('Checking…') : tr('Check it'))),
        const SizedBox(height: 14),
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
        if (result != null) ...[
          const SizedBox(height: 22),
          VerdictView(result: result!, trustedName: status['trustedName'] as String?, trustedNumber: status['trustedNumber'] as String?, onChanged: run),
        ] else ...[
          SectionLabel(tr('Good to know')),
          Panel(
            child: Text(
              tr('Real bank and company SMS in India come from sender names like VM-SBIINB-T, never from a 10-digit mobile number. The last letter tells you the type: T for transactions and OTPs, S for service, P for promotions, G for government.'),
              style: const TextStyle(height: 1.45),
            ),
          ),
        ],
      ]),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.title, required this.sub, required this.onTap});
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Panel(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 30),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(160))),
        ]),
      );
}
