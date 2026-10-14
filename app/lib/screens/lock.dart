import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';

/// Shown when App lock is on. Unlocks with the phone's own fingerprint / face / PIN prompt.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unlock());
  }

  Future<void> unlock() async {
    if (busy) return;
    setState(() => busy = true);
    final ok = await Native.instance.authenticate();
    if (!mounted) return;
    setState(() => busy = false);
    if (ok) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(color: cs.primary.withAlpha(28), borderRadius: BorderRadius.circular(28)),
                child: Icon(Icons.lock_rounded, size: 44, color: cs.primary),
              ),
              const SizedBox(height: 24),
              Text(tr('Second Look is locked'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(tr('Your alerts and marked numbers stay private.'), textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withAlpha(170))),
              const SizedBox(height: 28),
              FilledButton.icon(onPressed: busy ? null : unlock, icon: const Icon(Icons.fingerprint_rounded), label: Text(tr('Unlock'))),
            ]),
          ),
        ),
      ),
    );
  }
}
