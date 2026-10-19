import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Me → Crash reports: errors the app ran into, saved only on this phone. Nothing is sent unless the user taps
/// "Send report" (the phone's share sheet, so they choose where it goes).
class CrashLogScreen extends StatefulWidget {
  const CrashLogScreen({super.key});
  @override
  State<CrashLogScreen> createState() => _CrashLogScreenState();
}

class _CrashLogScreenState extends State<CrashLogScreen> {
  List<Map<String, dynamic>> items = [];
  bool loaded = false;
  bool busy = false;
  final open = <int>{};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final l = await Native.instance.crashLog();
    if (!mounted) return;
    setState(() {
      items = l;
      open.clear();
      loaded = true;
    });
  }

  static int _ms(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  String _when(BuildContext context, int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final loc = MaterialLocalizations.of(context);
    return '${loc.formatShortDate(d)} · ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(d))}';
  }

  Future<void> _send() async {
    if (busy) return;
    setState(() => busy = true);
    final ok = await Native.instance.shareCrashLog();
    if (!mounted) return;
    setState(() => busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t open sharing. Please try again.'))));
    } else if (Native.instance.isWeb) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Report copied. Paste it in an email to us.'))));
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Clear crash reports?')),
        content: Text(tr('This removes the saved crash reports from this phone.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Clear'))),
        ],
      ),
    );
    if (ok != true) return;
    final done = await Native.instance.clearCrashLog();
    if (!mounted) return;
    if (!done) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t save. Please try again.'))));
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: SL.ground,
      appBar: AppBar(
        leading: const Padding(padding: EdgeInsets.only(left: 8), child: Center(child: BackCircle())),
        leadingWidth: 60,
        title: Text(tr('Crash reports'), style: SL.h(22)),
        actions: [
          IconButton(tooltip: tr('Refresh'), onPressed: load, icon: const Icon(Icons.refresh_rounded)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(padding: EdgeInsets.fromLTRB(20, 4, 20, bottom + 24), children: [
        Panel(
          color: SL.accent.withAlpha(13),
          borderColor: SL.accent.withAlpha(70),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const IconTile(Icons.lock_outline_rounded, color: SL.accent, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Saved only on this phone. Nothing is sent unless you tap Send.'),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, height: 1.35)),
                const SizedBox(height: 4),
                Text(tr('When the app runs into a problem, a short technical note is kept here to help us fix it. Long numbers and links are removed from it.'),
                    style: const TextStyle(fontSize: 13.5, color: SL.textSecondary, height: 1.4)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        if (!loaded)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (items.isEmpty)
          Panel(
            child: Row(children: [
              const IconTile(Icons.check_rounded, color: SL.safeD, size: 40),
              const SizedBox(width: 12),
              Expanded(child: Text(tr('No crash reports. Everything has been running fine.'), style: const TextStyle(color: SL.textSoft, height: 1.4))),
            ]),
          )
        else ...[
          Row(children: [
            Expanded(
              child: GlowButton(
                label: tr('Send report'),
                icon: Icons.ios_share_rounded,
                height: 54,
                fontSize: 16,
                busy: busy,
                onPressed: _send,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SoftButton(
                label: tr('Clear'),
                icon: Icons.delete_outline_rounded,
                color: SL.dangerSoft,
                border: SL.dangerD.withAlpha(110),
                onPressed: busy ? null : _clear,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(tr('Send opens your phone\'s share options, so you choose where it goes.'), style: const TextStyle(fontSize: 12.5, color: SL.textMuted)),
          SectionLabel(tr('{n} saved', {'n': items.length})),
          for (var i = 0; i < items.length; i++) ...[
            _entry(context, i, items[i]),
            const SizedBox(height: 10),
          ],
        ],
      ]),
    );
  }

  Widget _entry(BuildContext context, int i, Map<String, dynamic> e) {
    final message = '${e['message'] ?? ''}'.trim();
    final stack = '${e['stack'] ?? ''}'.trim();
    final native = e['source'] == 'native';
    final isOpen = open.contains(i);
    final meta = [
      native ? tr('App (system part)') : tr('App'),
      if ('${e['app'] ?? ''}'.isNotEmpty) '${e['app']}',
      if ('${e['os'] ?? ''}'.isNotEmpty) '${e['os']}',
    ].join(' · ');
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: stack.isEmpty
          ? null
          : () => setState(() {
                if (isOpen) {
                  open.remove(i);
                } else {
                  open.add(i);
                }
              }),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: SL.warnD),
          const SizedBox(width: 8),
          Expanded(child: Text(_when(context, _ms(e['at'])), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: SL.textSecondary))),
          if (stack.isNotEmpty) Icon(isOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: SL.textMuted),
        ]),
        const SizedBox(height: 6),
        Text(message.isEmpty ? tr('Unknown error') : message,
            maxLines: isOpen ? null : 3,
            overflow: isOpen ? null : TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: SL.text, height: 1.35)),
        const SizedBox(height: 4),
        Text(meta, style: const TextStyle(fontSize: 12, color: SL.textMuted)),
        if (isOpen && stack.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0x33000000), borderRadius: BorderRadius.circular(12), border: Border.all(color: SL.hairline)),
            child: SelectableText(stack, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: SL.textSoft, height: 1.35)),
          ),
        ],
      ]),
    );
  }
}
