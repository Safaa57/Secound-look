import 'dart:io' if (dart.library.js_interop) '../web/no_io.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../checks/picker.dart';
import '../i18n/i18n.dart';
import '../monetize/monetize.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/verdict.dart';

/// Checks a "payment done" screenshot for signs that it's fake or edited.
class PaymentCheckScreen extends StatefulWidget {
  const PaymentCheckScreen({super.key, this.sharedPath, this.initialImage});

  /// Android: a screenshot shared to Second Look from another app.
  final String? sharedPath;

  /// A screenshot already picked and read on the Check screen.
  final PickedImage? initialImage;

  @override
  State<PaymentCheckScreen> createState() => _PaymentCheckScreenState();
}

class _PaymentCheckScreenState extends State<PaymentCheckScreen> {
  final words = TextEditingController();
  final expected = TextEditingController();
  final myUpi = TextEditingController();
  PickedImage? image;
  Map<String, dynamic>? result, status;
  bool busy = false;
  String? note; // English; shown with tr() so it follows the language

  /// This visit counts as one manual check (however often it's re-run); any ad comes after the user leaves.
  AdTicket? _ad;
  void _counted(Map<String, dynamic> r) {
    final t = _ad;
    if (t == null) {
      _ad = AdRules.manualCheck(r);
    } else {
      AdRules.update(t, r);
    }
  }

  @override
  void initState() {
    super.initState();
    Native.instance.status().then((s) => mounted ? setState(() => status = s) : null);
    final p = widget.sharedPath;
    if (p != null && !kIsWeb) _loadShared(p);
    final img = widget.initialImage;
    if (img != null) WidgetsBinding.instance.addPostFrameCallback((_) => _use(img));
  }

  @override
  void dispose() {
    words.dispose();
    expected.dispose();
    myUpi.dispose();
    AdRules.leaving(_ad);
    super.dispose();
  }

  Future<void> _loadShared(String path) async {
    setState(() => busy = true);
    try {
      final bytes = await File(path).readAsBytes();
      _use(await ImageReader.read(path, bytes));
    } catch (_) {
      if (mounted) setState(() => note = 'Couldn\'t open the shared image.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pick() async {
    setState(() {
      busy = true;
      note = null;
    });
    try {
      final img = await ImageReader.pick();
      if (img != null) _use(img);
    } on PlatformException catch (e) {
      if (mounted) setState(() => note = e.message ?? 'Couldn\'t open the photo picker.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _use(PickedImage img) {
    if (!mounted) return;
    setState(() {
      image = img.bytes.isEmpty ? null : img;
      result = null;
      note = img.readError;
      if (img.text.isNotEmpty) words.text = img.text;
    });
    if (img.text.isNotEmpty) _check();
  }

  Future<void> _check() async {
    final t = words.text.trim();
    if (t.isEmpty && image?.editor == null) {
      setState(() => note = 'Choose a screenshot, or type what it says (amount, date, reference number).');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => busy = true);
    try {
      final r = await Native.instance.analyzePayment(
        text: t,
        expectedAmount: expected.text.trim().isEmpty ? null : expected.text.trim(),
        myUpi: myUpi.text.trim().isEmpty ? null : myUpi.text.trim(),
        imageEditor: image?.editor,
      );
      if (mounted) {
        setState(() => result = r);
        _counted(r);
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => note = e.message ?? 'The check failed.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = (result?['info'] as Map?)?.cast<String, dynamic>() ?? {};
    return Scaffold(
      appBar: AppBar(title: Text(tr('Check a payment screenshot'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        Panel(
          color: SL.bg(context, 'warning'),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_rounded, color: SL.fg(context, 'warning')),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr('A screenshot is never proof of payment. This check spots common signs of fake or edited screenshots, '
                    'but the only real proof is the money in your own bank or UPI app.'),
                style: TextStyle(color: SL.fg(context, 'warning'), fontWeight: FontWeight.w600, height: 1.4),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        if (image != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: Image.memory(image!.bytes, fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: busy ? null : _pick,
          icon: const Icon(Icons.image_search_rounded),
          label: Text(image == null ? tr('Choose the screenshot') : tr('Choose a different screenshot')),
        ),
        if (!kIsWeb)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(tr('Read on your phone. The image is never uploaded.'), style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(140))),
          ),
        if (note != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(tr(note!), style: TextStyle(color: SL.fg(context, 'warning')))),
        const SizedBox(height: 14),
        TextField(
          controller: words,
          minLines: 3,
          maxLines: 8,
          maxLength: 10000,
          decoration: InputDecoration(
            labelText: tr('What the screenshot says'),
            hintText: tr('e.g. Payment successful ₹5,000 · 13 Oct 2026, 10:32 am · UPI Ref No 628612345678'),
            helperText: tr('Filled in automatically on the phone. Fix any misread numbers.'),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: expected,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(14)],
              decoration: InputDecoration(labelText: tr('Amount you expected'), prefixText: '₹ '),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: myUpi,
              inputFormatters: [LengthLimitingTextInputFormatter(64)],
              decoration: InputDecoration(labelText: tr('Your UPI ID'), hintText: 'name@bank'),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: busy ? null : _check,
          icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fact_check_rounded),
          label: Text(busy ? tr('Checking…') : tr('Check payment')),
        ),
        if (result != null) ...[
          const SizedBox(height: 22),
          if (info.isNotEmpty) _FoundCard(info: info, editor: image?.editor),
          const SizedBox(height: 12),
          VerdictView(result: result!, trustedName: status?['trustedName'] as String?, trustedNumber: status?['trustedNumber'] as String?),
        ] else ...[
          SectionLabel(tr('Common fake-payment tricks')),
          Panel(
            child: Text(
              [
                tr('"Payment pending, it will reflect in 24 hours." UPI is instant.'),
                tr('"I sent extra by mistake, please return it." Check your balance first.'),
                tr('An old or edited screenshot of someone else\'s payment.'),
                tr('Fake "prank" payment apps that make a real-looking receipt.'),
                tr('A fake "credited" SMS from a 10-digit mobile number.'),
              ].map((l) => '• $l').join('\n'),
              style: const TextStyle(height: 1.6),
            ),
          ),
        ],
      ]),
    );
  }
}

class _FoundCard extends StatelessWidget {
  const _FoundCard({required this.info, this.editor});
  final Map<String, dynamic> info;
  final String? editor;

  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[
      if (info['amountText'] != null) [tr('Amount'), '₹${info['amountText']}'],
      if (info['status'] != null) [tr('Status'), _statusWord('${info['status']}')],
      if (info['ref'] != null) [tr('UPI reference'), '${info['ref']}'],
      if (info['txnId'] != null) [tr('Transaction ID'), '${info['txnId']}'],
      if (info['date'] != null) [tr('Date'), '${info['date']}${info['time'] != null ? ', ${info['time']}' : ''}'],
      if (info['upiIds'] != null) [tr('UPI IDs'), (info['upiIds'] as List).join(', ')],
      [tr('Photo editor in file'), editor != null ? tr('Yes, saved by a photo-editing app') : tr('None found (normal for forwarded images)')],
    ];
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Found on the screenshot'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 130, child: Text(r[0], style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(150)))),
              Expanded(child: SelectableText(r[1], style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
        const SizedBox(height: 6),
        Text(tr('Search for this reference number in your bank or UPI app\'s transaction history.'),
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(150))),
      ]),
    );
  }
}

/// Payment status word from the engine ('successful', 'pending', 'failed').
String _statusWord(String s) {
  switch (s) {
    case 'successful':
      return tr('successful');
    case 'pending':
      return tr('pending');
    case 'failed':
      return tr('failed');
    default:
      return s;
  }
}
