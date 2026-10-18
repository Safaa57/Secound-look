import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/i18n.dart';

/// Version of the Terms and Privacy Policy. Change it when either document changes in a meaningful way:
/// everyone is then asked to accept the new version.
const kLegalVersion = '2026-10-18';

/// Who runs this copy of Second Look. Set these at build time (see docs/legal/LEGAL_CHECKLIST.md), e.g.
/// --dart-define=SL_OPERATOR="Ayesha Khan (Second Look)" --dart-define=SL_GRIEVANCE_EMAIL=grievance@example.in
class Operator {
  static const name = String.fromEnvironment('SL_OPERATOR', defaultValue: '[Operator name]');
  static const address = String.fromEnvironment('SL_ADDRESS', defaultValue: '[Registered address]');
  static const email = String.fromEnvironment('SL_EMAIL', defaultValue: '[support email]');
  static const grievanceName = String.fromEnvironment('SL_GRIEVANCE_NAME', defaultValue: '[Grievance Officer name]');
  static const grievanceEmail = String.fromEnvironment('SL_GRIEVANCE_EMAIL', defaultValue: '[grievance email]');
  static const city = String.fromEnvironment('SL_CITY', defaultValue: '[City]');

  static String fill(String s) => s
      .replaceAll('{{OPERATOR}}', name)
      .replaceAll('{{ADDRESS}}', address)
      .replaceAll('{{EMAIL}}', email)
      .replaceAll('{{GRIEVANCE_NAME}}', grievanceName)
      .replaceAll('{{GRIEVANCE_EMAIL}}', grievanceEmail)
      .replaceAll('{{CITY}}', city)
      .replaceAll('{{EFFECTIVE}}', _pretty(kLegalVersion))
      .replaceAll('{{VERSION}}', kLegalVersion);

  static String _pretty(String iso) {
    const m = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    final p = iso.split('-');
    return '${int.parse(p[2])} ${m[int.parse(p[1]) - 1]} ${p[0]}';
  }
}

/// Shows one of the bundled legal documents (assets/legal/*.md) as readable text.
class LegalDocScreen extends StatelessWidget {
  const LegalDocScreen({super.key, required this.asset, required this.title});
  final String asset, title;

  static void open(BuildContext context, String which) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => which == 'terms'
            ? LegalDocScreen(asset: 'assets/legal/terms.md', title: tr('Terms of Use'))
            : LegalDocScreen(asset: 'assets/legal/privacy.md', title: tr('Privacy Policy')),
      ));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: FutureBuilder<String>(
          future: rootBundle.loadString(asset),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return SelectionArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: [
                  if (L10n.lang.value != 'en')
                    Container(
                      margin: const EdgeInsets.only(top: 4, bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                      child: Row(children: [
                        Icon(Icons.translate_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 10),
                        Expanded(child: Text(tr('This document is in English. The English version applies.'), style: const TextStyle(fontWeight: FontWeight.w600))),
                      ]),
                    ),
                  ..._render(context, Operator.fill(snap.data!)),
                ],
              ),
            );
          },
        ),
      );

  /// A tiny Markdown renderer for our own documents: headings, bullets, bold, simple tables.
  static List<Widget> _render(BuildContext context, String md) {
    final cs = Theme.of(context).colorScheme;
    final out = <Widget>[];
    for (final raw in md.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        out.add(const SizedBox(height: 8));
      } else if (line.startsWith('# ')) {
        out.add(Text(line.substring(2), style: Theme.of(context).textTheme.headlineMedium));
      } else if (line.startsWith('## ')) {
        out.add(Padding(padding: const EdgeInsets.only(top: 14, bottom: 4), child: Text(line.substring(3), style: Theme.of(context).textTheme.titleLarge)));
      } else if (line.startsWith('|')) {
        if (RegExp(r'^\|[\s|:-]+\|$').hasMatch(line)) continue;
        final cells = line.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
        out.add(Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cs.onSurface.withAlpha(12), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < cells.length; i++)
              Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: _rich(cells[i], bold: i == 0)),
          ]),
        ));
      } else if (line.startsWith('- ')) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: 4, top: 3, bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  ', style: TextStyle(fontSize: 15)),
            Expanded(child: _rich(line.substring(2))),
          ]),
        ));
      } else {
        out.add(_rich(line));
      }
    }
    return out;
  }

  static Widget _rich(String s, {bool bold = false}) {
    final spans = <TextSpan>[];
    final parts = s.split('**');
    for (var i = 0; i < parts.length; i++) {
      spans.add(TextSpan(text: parts[i], style: TextStyle(fontWeight: (bold || i.isOdd) ? FontWeight.w700 : FontWeight.w400)));
    }
    return Text.rich(TextSpan(children: spans), style: const TextStyle(fontSize: 15, height: 1.5));
  }
}

/// Checkbox + links used at first launch and when the documents change.
class ConsentBox extends StatelessWidget {
  const ConsentBox({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final link = TextStyle(color: cs.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Wrap(children: [
            Text(tr('I have read and agree to the ')),
            GestureDetector(onTap: () => LegalDocScreen.open(context, 'terms'), child: Text(tr('Terms of Use'), style: link)),
            Text(tr(' and ')),
            GestureDetector(onTap: () => LegalDocScreen.open(context, 'privacy'), child: Text(tr('Privacy Policy'), style: link)),
            Text(tr('. I understand results are automated opinions, not guarantees.')),
          ]),
        ),
      ),
    ]);
  }
}

/// Shown to existing users when the Terms or Privacy Policy change.
class ConsentUpdateScreen extends StatefulWidget {
  const ConsentUpdateScreen({super.key, required this.onAccepted});
  final VoidCallback onAccepted;
  @override
  State<ConsentUpdateScreen> createState() => _ConsentUpdateScreenState();
}

class _ConsentUpdateScreenState extends State<ConsentUpdateScreen> {
  bool agreed = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(24, 40, 24, 24), children: [
            Icon(Icons.policy_rounded, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 18),
            Text(tr('We updated our Terms and Privacy Policy'), style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(tr('Please read them and agree to keep using Second Look. Your messages, calls and contacts still never leave your device.'),
                style: const TextStyle(fontSize: 16, height: 1.5)),
            const SizedBox(height: 18),
            ConsentBox(value: agreed, onChanged: (v) => setState(() => agreed = v)),
            const SizedBox(height: 18),
            FilledButton(onPressed: agreed ? widget.onAccepted : null, child: Text(tr('Continue'))),
          ]),
        ),
      );
}

/// Licences and attributions for data and code we include (shown on the Open-source licences page).
void registerLicences() {
  LicenseRegistry.addLicense(() => Stream<LicenseEntry>.fromIterable([
        const LicenseEntryWithLineBreaks(['libphonenumber (Google)'],
            'Copyright (C) Google Inc. Licensed under the Apache License, Version 2.0. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.'),
        const LicenseEntryWithLineBreaks(['libphonenumber-js'], 'Copyright (c) Nikolay Kuchumov. Released under the MIT License.'),
        const LicenseEntryWithLineBreaks(['Indian number series and telecom circle data'],
            'Adapted from Wikipedia articles on Indian mobile numbering and telecom circles, by Wikipedia contributors, licensed under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). Our adapted data file (phone_data.json) is shared under the same licence.'),
        const LicenseEntryWithLineBreaks(['Phishing.Database (used by the Deep check server)'], 'Phishing.Database by Mitchell Krog and Nissar Chababy. MIT License.'),
        const LicenseEntryWithLineBreaks(['Google Web Risk'], 'Advisory provided by Google: https://docs.cloud.google.com/web-risk/docs/advisory. Google cannot guarantee that its information is comprehensive and error-free.'),
      ]));
  // The two bundled fonts (SIL Open Font License 1.1); the full licence texts ship beside the font files.
  LicenseRegistry.addLicense(() async* {
    for (final f in const [
      ['Sora (font)', 'assets/fonts/OFL-Sora.txt'],
      ['Manrope (font)', 'assets/fonts/OFL-Manrope.txt'],
    ]) {
      try {
        yield LicenseEntryWithLineBreaks([f[0]], await rootBundle.loadString(f[1]));
      } catch (_) {
        yield LicenseEntryWithLineBreaks([f[0]], 'Licensed under the SIL Open Font License, Version 1.1 (https://openfontlicense.org).');
      }
    }
  });
  if (kDebugMode) debugPrint('Second Look licences registered');
}
