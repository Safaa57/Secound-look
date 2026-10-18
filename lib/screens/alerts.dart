import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import 'shield_health.dart';

/// Every SMS and call Second Look checked (kept only on this phone), with quick marks, and the history of marks.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<Map<String, dynamic>> items = [];
  List<Map<String, dynamic>> marks = [];
  Map<String, dynamic> status = {};
  String filter = 'all';
  bool whatsApp = false;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    alertsVersion.addListener(load);
    load();
  }

  @override
  void dispose() {
    alertsVersion.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    List<Map<String, dynamic>> h = items;
    try {
      h = await Native.instance.history();
    } catch (_) {}
    final acts = await Native.instance.numberActions();
    final wa = await Native.instance.isAppInstalled('whatsapp');
    Map<String, dynamic> st = status;
    try {
      st = await Native.instance.status();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      items = h;
      marks = acts;
      whatsApp = wa;
      status = st;
      loaded = true;
    });
  }

  Future<void> _loadMarks() async {
    final acts = await Native.instance.numberActions();
    if (mounted) setState(() => marks = acts);
  }

  bool get _phone => !Native.instance.isWeb && status['platform'] != 'web' && status['platform'] != 'ios';

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Clear all alerts?')),
        content: Text(tr('This removes the list of checked SMS and calls from this phone. Numbers you marked stay marked.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Clear all'))),
        ],
      ),
    );
    if (ok != true) return;
    await Native.instance.clearHistory();
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final danger = items.where((a) => a['level'] == 'danger').length;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: load,
          child: ListView(padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 24), children: [
            Row(children: [
              Expanded(child: Text(tr('Alerts'), maxLines: 1, overflow: TextOverflow.ellipsis, style: SL.h(28))),
              _RoundIcon(icon: Icons.refresh_rounded, tooltip: tr('Refresh'), onTap: load),
              if (items.isNotEmpty) ...[const SizedBox(width: 8), _RoundIcon(icon: Icons.delete_sweep_outlined, tooltip: tr('Clear all'), onTap: _clearAll)],
            ]),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _filter('all', tr('All')),
                _filter('danger', danger > 0 ? '${tr('Danger')} $danger' : tr('Danger')),
                _filter('call', tr('Calls')),
                _filter('marked', tr('Marked')),
              ]),
            ),
            const SizedBox(height: 14),
            if (filter == 'marked') ..._marksList(context) else ..._alertsList(context),
          ]),
        ),
      ),
    );
  }

  List<Widget> _alertsList(BuildContext context) {
    final shown = items.where((a) {
      switch (filter) {
        case 'danger':
          return a['level'] == 'danger';
        case 'call':
          return a['kind'] == 'call';
        default:
          return true;
      }
    }).toList();
    if (!loaded) return const [Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))];
    if (shown.isEmpty) {
      return [
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const IconTile(Icons.notifications_none_rounded, color: SL.accent),
            const SizedBox(height: 12),
            Text(
              tr('Nothing here yet. Each SMS and call that Second Look checks is listed here, only on this phone.'),
              style: const TextStyle(color: SL.textSoft, height: 1.4),
            ),
            if (_phone) ...[
              const SizedBox(height: 10),
              Text(tr('Not seeing new SMS or calls? Run a Protection check.'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShieldHealthScreen())),
                icon: const Icon(Icons.health_and_safety_outlined),
                label: Text(tr('Protection check')),
              ),
            ],
          ]),
        ),
      ];
    }
    return [
      for (final a in shown) ...[
        AlertCard(key: ValueKey('${a['id']}'), a: a, whatsApp: whatsApp, onChanged: _loadMarks),
        const SizedBox(height: 12),
      ],
    ];
  }

  /// A filter chip: solid cyan when chosen, outlined otherwise.
  Widget _filter(String key, String label) {
    final on = filter == key;
    final r = BorderRadius.circular(20);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        selected: on,
        button: true,
        child: Material(
          color: on ? SL.accent : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: r, side: on ? BorderSide.none : const BorderSide(color: Color(0x338CDCFF))),
          child: InkWell(
            borderRadius: r,
            onTap: () => setState(() => filter = key),
            child: Container(
              height: 40,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: on ? SL.onAccent : SL.text)),
            ),
          ),
        ),
      ),
    );
  }

  /// "Marked": every number and sender the user marked, newest first, with undo.
  List<Widget> _marksList(BuildContext context) {
    // Only the newest mark of each number can be undone, and only if it's still in effect.
    final undoable = <int>{};
    final seen = <String>{};
    for (var i = 0; i < marks.length; i++) {
      final n = '${marks[i]['number'] ?? ''}';
      final act = '${marks[i]['action'] ?? ''}';
      if (act == 'comment' || seen.contains(n)) continue;
      seen.add(n);
      if (act != 'unblock') undoable.add(i);
    }
    return [
      Text(tr('Numbers and senders you marked. Kept only on this phone.'), style: const TextStyle(color: SL.textSecondary)),
      const SizedBox(height: 12),
      if (marks.isEmpty)
        Panel(child: Text(tr('No marked alerts yet. Use Block, Spam, Fraud, Safe or Comment on any alert.'), style: const TextStyle(height: 1.4)))
      else
        for (var i = 0; i < marks.length; i++) ...[
          _markRow(context, marks[i], undoable.contains(i)),
          const SizedBox(height: 10),
        ],
    ];
  }

  Widget _markRow(BuildContext context, Map<String, dynamic> e, bool canUndo) {
    final number = '${e['number'] ?? ''}';
    final action = '${e['action'] ?? ''}';
    final comment = '${e['comment'] ?? ''}'.trim();
    final at = e['at'] is num ? (e['at'] as num).toInt() : int.tryParse('${e['at']}') ?? 0;
    final level = markLevel(action);
    final c = action == 'comment' ? SL.accent : SL.fgOf(level);
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconTile(markIcon(action), color: c, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(number, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 2),
            Text('${markLabel(action)}${at > 0 ? ' · ${timeAgo(at)}' : ''}', style: TextStyle(fontSize: 13, color: c, fontWeight: FontWeight.w700)),
            if (comment.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(comment, style: const TextStyle(fontSize: 13.5, color: SL.textSoft)),
            ],
          ]),
        ),
        if (canUndo)
          TextButton(
            onPressed: () => _undo(number, action),
            child: Text(action == 'block' ? tr('Unblock') : tr('Remove')),
          ),
      ]),
    );
  }

  Future<void> _undo(String number, String action) async {
    final ok = await Native.instance.markNumber(number, 'unblock');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? (action == 'block' ? tr('Unblocked.') : tr('Mark removed.')) : tr('Couldn\'t save. Please try again.')),
    ));
    if (ok) await load();
  }
}

/// A 44 px round icon button in the header.
class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(side: BorderSide(color: Color(0x2E8CDCFF))),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 21, color: SL.text)),
          ),
        ),
      );
}
