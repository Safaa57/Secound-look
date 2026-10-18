import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import 'common.dart';

/// Shown right after a number is blocked in Second Look: says plainly what that does (and doesn't) block,
/// and offers to block it in the phone itself too.
Future<void> showBlockedSheet(BuildContext context, String number) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BlockedSheet(number: number),
    );

class _BlockedSheet extends StatefulWidget {
  const _BlockedSheet({required this.number});
  final String number;
  @override
  State<_BlockedSheet> createState() => _BlockedSheetState();
}

class _BlockedSheetState extends State<_BlockedSheet> {
  bool busy = false;
  bool showSteps = false;

  Future<void> _blockInPhone() async {
    if (busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    setState(() => busy = true);
    final ok = await Native.instance.openBlockedNumbers(widget.number);
    if (!mounted) return;
    if (ok) {
      nav.pop();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(tr('Number copied — tap + / Add and paste it'))));
      return;
    }
    setState(() {
      busy = false;
      showSteps = true;
    });
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: widget.number));
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(tr('Number copied'))));
  }

  Widget _line(IconData icon, String text, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconTile(icon, color: color, size: 34),
          const SizedBox(width: 12),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 6), child: Text(text, style: const TextStyle(fontSize: 15, height: 1.4)))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final danger = SL.fg(context, 'danger');
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(165);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              IconTile(Icons.block_rounded, color: danger, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Blocked in Second Look'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                  Text(widget.number, style: TextStyle(color: muted, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
            const SizedBox(height: 10),
            _line(Icons.call_end_rounded, tr('Calls from this number are rejected while Call Shield is on.'), SL.fg(context, 'safe')),
            _line(Icons.sms_rounded, tr('SMS still arrive in your Messages app — Second Look just won\'t alert you.'), SL.fg(context, 'warning')),
            _line(Icons.phonelink_lock_rounded, tr('To block calls and SMS everywhere, permanently, also block it in your phone.'), SL.accent),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: busy ? null : _blockInPhone,
              icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.phone_locked_rounded),
              label: Text(tr('Block in phone too')),
            ),
            if (showSteps) ...[
              const SizedBox(height: 14),
              Panel(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Block it in your phone'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                  const SizedBox(height: 6),
                  Text(tr('iPhone: open Phone → Recents, tap ⓘ next to the number, then "Block this Caller". This blocks calls and messages.'),
                      style: const TextStyle(height: 1.4)),
                  const SizedBox(height: 6),
                  Text(tr('Other phones: open the number in your Phone app, tap ⋮ or ⓘ, then Block.'), style: const TextStyle(height: 1.4)),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(onPressed: _copy, icon: const Icon(Icons.copy_rounded, size: 18), label: Text(tr('Copy number'))),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 6),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Done'))),
          ]),
        ),
      ),
    );
  }
}
