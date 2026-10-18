import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// "I think I'm being scammed" — calm, numbered steps with one-tap actions.
class PanicScreen extends StatelessWidget {
  const PanicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final steps = <List<String>>[
      [tr('Stop talking and hang up'), tr('Real police, banks and officials never mind if you hang up and call them back. "Digital arrest" does not exist.')],
      [tr('Don\'t share or approve anything'), tr('No OTP, UPI PIN, card number or screen sharing. Don\'t scan QR codes or approve payment requests.')],
      [tr('Uninstall apps they asked for'), tr('Remove any screen-sharing or remote-control app, or any APK they sent. Turn on flight mode if you\'re unsure.')],
      [tr('Block your bank access'), tr('Call the number on the back of your card, or block UPI and cards inside your banking app.')],
      [tr('Report within the first hour'), tr('Call 1930. Fast reports give the best chance to freeze the money.')],
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Being scammed?')), actions: const [LanguageButton()]),
      body: ListView(padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.paddingOf(context).bottom + 32), children: [
        Panel(
          radius: 24,
          padding: const EdgeInsets.all(18),
          color: SL.dangerD.withAlpha(18),
          borderColor: SL.dangerD.withAlpha(102),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Take a breath. You can still stop this.'), style: SL.h(24, color: SL.dangerLight, height: 1.2)),
            const SizedBox(height: 8),
            Text(tr('Scammers rush you on purpose. Follow these steps in order.'), style: const TextStyle(fontSize: 15.5, color: SL.textSoft, height: 1.4)),
            const SizedBox(height: 16),
            GlowButton(
              icon: Icons.call_rounded,
              color: SL.dangerD,
              textColor: SL.onDanger,
              height: 60,
              radius: 18,
              fontSize: 17,
              onPressed: () => Native.instance.dial('1930'),
              label: tr('Call 1930 · Cyber Crime Helpline'),
            ),
          ]),
        ),
        SectionLabel(tr('Do this now')),
        for (var i = 0; i < steps.length; i++) ...[
          Panel(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: SL.accent.withAlpha(36), shape: BoxShape.circle, border: Border.all(color: SL.accent.withAlpha(102))),
                child: Text('${i + 1}', style: SL.h(14, color: SL.accent)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(steps[i][0], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 3),
                  Text(steps[i][1], style: const TextStyle(color: SL.textSoft, height: 1.4)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 10),
        ],
        SectionLabel(tr('Report online')),
        OutlinedButton.icon(onPressed: () => Native.instance.openUrl('https://cybercrime.gov.in'), icon: const Icon(Icons.open_in_new_rounded), label: const Text('cybercrime.gov.in')),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: () => Native.instance.openUrl('https://sancharsaathi.gov.in'), icon: const Icon(Icons.open_in_new_rounded), label: Text(tr('Report fraud calls/SMS on Chakshu'))),
      ]),
    );
  }
}
