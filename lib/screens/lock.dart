import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  color: const Color(0xFF071A21),
                  shape: BoxShape.circle,
                  border: Border.all(color: SL.accent, width: 2),
                  boxShadow: [BoxShadow(color: SL.accent.withAlpha(100), blurRadius: 40)],
                ),
                child: const Icon(Icons.lock_outline_rounded, size: 50, color: SL.accent),
              ),
              const SizedBox(height: 28),
              Text(tr('Second Look is locked'), textAlign: TextAlign.center, style: SL.h(26)),
              const SizedBox(height: 8),
              Text(tr('Your alerts and marked numbers stay private.'), textAlign: TextAlign.center, style: const TextStyle(color: SL.textSecondary, fontSize: 15)),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: GlowButton(icon: Icons.fingerprint_rounded, label: tr('Unlock'), busy: busy, onPressed: unlock),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
