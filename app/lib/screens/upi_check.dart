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

/// Checks a UPI ID, a upi:// payment link or a QR code before paying.
class UpiCheckScreen extends StatefulWidget {
  const UpiCheckScreen({super.key});
  @override
  State<UpiCheckScreen> createState() => _UpiCheckScreenState();
}

class _UpiCheckScreenState extends State<UpiCheckScreen> {
  final input = TextEditingController();
  Map<String, dynamic>? result, status;
  String? decoded, note; // note is English; shown with tr() so it follows the language
  bool busy = false;

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
  }

  @override
  void dispose() {
    input.dispose();
    AdRules.leaving(_ad);
    super.dispose();
  }

  Future<void> _check([String? value]) async {
    final v = (value ?? input.text).trim();
    if (v.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      note = null;
    });
    try {
      // upi:// links and name@bank go to the UPI check; anything else (a web link in a QR code) to the normal check.
      final isUpi = RegExp(r'^upi:', caseSensitive: false).hasMatch(v) || RegExp(r'^[a-zA-Z0-9._-]{2,64}@[a-zA-Z][a-zA-Z0-9]{1,30}$').hasMatch(v);
      final r = isUpi ? await Native.instance.analyzeUpi(v) : await Native.instance.analyze(v);
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

  Future<void> _scan({required bool camera}) async {
    setState(() {
      busy = true;
      note = null;
      decoded = null;
    });
    try {
      final img = await ImageReader.pick(camera: camera);
      if (!mounted || img == null) return;
      if (img.readError != null) {
        setState(() => note = img.readError);
        return;
      }
      if (img.qr.isEmpty) {
        setState(() => note = 'No QR code found in that picture. Try a sharper, closer photo.');
        return;
      }
      final code = img.qr.first;
      setState(() {
        decoded = code;
        input.text = code.length > 2048 ? code.substring(0, 2048) : code;
      });
      await _check(code);
    } on PlatformException catch (e) {
      if (mounted) setState(() => note = e.message ?? 'Couldn\'t open the camera or photos.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = (result?['info'] as Map?)?.cast<String, dynamic>() ?? {};
    return Scaffold(
      appBar: AppBar(title: Text(tr('Check before you pay'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        Text(tr('Check a UPI ID, a payment link or a QR code someone sent you.'), style: TextStyle(color: cs.onSurface.withAlpha(170))),
        const SizedBox(height: 14),
        TextField(
          controller: input,
          maxLength: 2048,
          decoration: InputDecoration(labelText: tr('UPI ID or payment link'), hintText: tr('e.g. name@okaxis  or  upi://pay?pa=…')),
          onSubmitted: (_) => _check(),
        ),
        const SizedBox(height: 6),
        FilledButton.icon(onPressed: busy ? null : _check, icon: const Icon(Icons.shield_rounded), label: Text(busy ? tr('Checking…') : tr('Check it'))),
        if (!kIsWeb) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: busy ? null : () => _scan(camera: true), icon: const Icon(Icons.photo_camera_rounded), label: Text(tr('Photo of QR')))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(onPressed: busy ? null : () => _scan(camera: false), icon: const Icon(Icons.qr_code_2_rounded), label: Text(tr('QR from gallery')))),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(tr('QR codes are read on your phone. Nothing is uploaded.'), style: TextStyle(fontSize: 12.5, color: cs.onSurface.withAlpha(140))),
          ),
        ],
        if (note != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(tr(note!), style: TextStyle(color: SL.fg(context, 'warning')))),
        if (decoded != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Panel(child: SelectableText('${tr('The QR code contains:')}\n$decoded', style: const TextStyle(height: 1.4))),
          ),
        if (result != null) ...[
          const SizedBox(height: 18),
          if (result!['kind'] == 'upi' && info['vpa'] != null) _PayeeCard(info: info),
          const SizedBox(height: 12),
          VerdictView(result: result!, trustedName: status?['trustedName'] as String?, trustedNumber: status?['trustedNumber'] as String?),
        ] else ...[
          SectionLabel(tr('Remember')),
          Panel(
            child: Text(
              [
                tr('You never scan a QR code, enter a UPI PIN or approve a request to RECEIVE money.'),
                tr('After you enter a UPI ID, your UPI app shows the real registered name. Stop if it isn\'t who you expected.'),
                tr('A shop\'s QR sticker can be covered with a fake one. Check the name before paying.'),
              ].map((l) => '• $l').join('\n'),
              style: const TextStyle(height: 1.6),
            ),
          ),
        ],
      ]),
    );
  }
}

class _PayeeCard extends StatelessWidget {
  const _PayeeCard({required this.info});
  final Map<String, dynamic> info;
  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[
      [tr('UPI ID'), '${info['vpa']}'],
      [tr('UPI handle'), info['app'] != null ? tr('@{h} (a recognised UPI provider)', {'h': info['handle']}) : tr('@{h} (not recognised)', {'h': info['handle']})],
      if (info['payee'] != null) [tr('Name in the link'), '${info['payee']}'],
      if (info['amountText'] != null) [tr('Amount asked'), '${info['amountText']}'],
      if (info['note'] != null) [tr('Note'), '${info['note']}'],
      if (info['personal'] == true) [tr('Type'), tr('Personal (mobile number) UPI ID')],
    ];
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 120, child: Text(r[0], style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(150)))),
              Expanded(child: SelectableText(r[1], style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
      ]),
    );
  }
}
