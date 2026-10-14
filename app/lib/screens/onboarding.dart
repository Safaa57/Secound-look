import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../legal/legal.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Three calm screens: what it does, the privacy promise, and that the user stays in control.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final pc = PageController();
  int page = 0;
  bool agreed = false;

  List<_Page> get pages => [
    _Page(
      icon: Icons.shield_rounded,
      title: tr('Take a second look\nbefore you tap'),
      text: tr('Second Look checks SMS, links and calls for scam tricks: fake KYC alerts, UPI "receive money" traps, digital-arrest calls, fake couriers and look-alike websites.'),
      points: [tr('Clear verdicts: Safe, Suspicious or Likely scam'), tr('Plain-language reasons, not just a red label'), tr('What to do next, including one-tap 1930')],
    ),
    _Page(
      icon: Icons.lock_rounded,
      title: tr('Your messages never\nleave your phone'),
      text: tr('Second Look doesn\'t upload your contacts or messages. Checks run on the device. Only the optional Deep check sends a link you choose to be checked online.'),
      points: [tr('No contact uploads, no names database'), tr('No account or sign-up needed'), tr('Delete everything with one tap')],
    ),
    _Page(
      icon: Icons.toggle_on_rounded,
      title: tr('You\'re in control'),
      text: tr('SMS Shield and Call Shield stay OFF until you switch them on. Your phone will ask for permission, and you can switch them off any time.'),
      points: [tr('SMS Shield: checks new texts as they arrive'), tr('Call Shield: tells you who\'s calling while it rings'), tr('Pause either shield whenever you like')],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = this.pages;
    final last = page == pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const Align(
            alignment: Alignment.centerRight,
            child: Padding(padding: EdgeInsets.fromLTRB(0, 8, 12, 0), child: LanguageButton()),
          ),
          Expanded(
            child: PageView(
              controller: pc,
              onPageChanged: (i) => setState(() => page = i),
              children: pages,
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < pages.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: i == page ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(color: i == page ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface.withAlpha(40), borderRadius: BorderRadius.circular(4)),
              ),
          ]),
          if (last)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 20, 0),
              child: ConsentBox(value: agreed, onChanged: (v) => setState(() => agreed = v)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Row(children: [
              if (!last)
                TextButton(
                  onPressed: () => pc.animateToPage(pages.length - 1, duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                  child: Text(tr('Skip')),
                ),
              const Spacer(),
              FilledButton(
                onPressed: last ? (agreed ? widget.onDone : null) : () => pc.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: Text(last ? tr('Get started') : tr('Next'))),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.icon, required this.title, required this.text, required this.points});
  final IconData icon;
  final String title, text;
  final List<String> points;
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(24, 40, 24, 12), children: [
        Container(
          width: 84,
          height: 84,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withAlpha(28), borderRadius: BorderRadius.circular(26)),
          child: Icon(icon, size: 44, color: Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(height: 28),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 14),
        Text(text, style: TextStyle(fontSize: 16.5, height: 1.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(185))),
        const SizedBox(height: 22),
        Panel(
          child: Column(children: [
            for (final p in points)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Icon(Icons.check_circle_rounded, color: SL.fg(context, 'safe'), size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Text(p, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))),
                ]),
              ),
          ]),
        ),
      ]);
}
