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
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text(tr('Alerts')),
            actions: [
              const LanguageButton(),
              IconButton(tooltip: tr('Refresh'), onPressed: load, icon: const Icon(Icons.refresh_rounded)),
              if (items.isNotEmpty) IconButton(tooltip: tr('Clear all'), onPressed: _clearAll, icon: const Icon(Icons.delete_sweep_rounded)),
            ],
            bottom: TabBar(tabs: [
              Tab(text: tr('Checked')),
              Tab(text: marks.isEmpty ? tr('My marks') : '${tr('My marks')} (${marks.length})'),
            ]),
          ),
          body: TabBarView(children: [_alertsTab(context), _marksTab(context)]),
        ),
      );

  Widget _alertsTab(BuildContext context) {
    final shown = items.where((a) {
      switch (filter) {
        case 'sms':
          return a['kind'] == 'sms';
        case 'call':
          return a['kind'] == 'call';
        case 'marked':
          return alertMark(a) != null;
        default:
          return true;
      }
    }).toList();
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 32), children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          _filter('all', tr('All'), null),
          _filter('sms', 'SMS', Icons.sms_rounded),
          _filter('call', tr('Calls'), Icons.call_rounded),
          _filter('marked', tr('Marked'), Icons.bookmark_rounded),
        ]),
        const SizedBox(height: 14),
        if (!loaded)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (shown.isEmpty)
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                filter == 'marked'
                    ? tr('No marked alerts yet. Use Block, Spam, Fraud, Safe or Comment on any alert.')
                    : tr('Nothing here yet. Each SMS and call that Second Look checks is listed here, only on this phone.'),
                style: TextStyle(color: cs.onSurface.withAlpha(180), height: 1.4),
              ),
              if (_phone && filter != 'marked') ...[
                const SizedBox(height: 10),
                Text(tr('Not seeing new SMS or calls? Run a Protection check.'), style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShieldHealthScreen())),
                  icon: const Icon(Icons.health_and_safety_rounded),
                  label: Text(tr('Protection check')),
                ),
              ],
            ]),
          )
        else
          for (final a in shown) ...[
            AlertCard(key: ValueKey('${a['id']}'), a: a, whatsApp: whatsApp, onChanged: _loadMarks),
            const SizedBox(height: 10),
          ],
      ]),
    );
  }

  Widget _filter(String key, String label, IconData? icon) => ChoiceChip(
        label: Text(label),
        avatar: icon == null ? null : Icon(icon, size: 17),
        selected: filter == key,
        onSelected: (_) => setState(() => filter = key),
      );

  Widget _marksTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 32), children: [
        Text(tr('Numbers and senders you marked. Kept only on this phone.'), style: TextStyle(color: cs.onSurface.withAlpha(160))),
        const SizedBox(height: 12),
        if (marks.isEmpty)
          Panel(child: Text(tr('Nothing marked yet. In the Checked tab, tap Block, Spam, Fraud, Safe or Comment on any alert.'), style: const TextStyle(height: 1.4)))
        else
          for (var i = 0; i < marks.length; i++) ...[
            _markRow(context, marks[i], undoable.contains(i)),
            const SizedBox(height: 8),
          ],
      ]),
    );
  }

  Widget _markRow(BuildContext context, Map<String, dynamic> e, bool canUndo) {
    final cs = Theme.of(context).colorScheme;
    final number = '${e['number'] ?? ''}';
    final action = '${e['action'] ?? ''}';
    final comment = '${e['comment'] ?? ''}'.trim();
    final at = e['at'] is num ? (e['at'] as num).toInt() : int.tryParse('${e['at']}') ?? 0;
    final level = markLevel(action);
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: SL.bg(context, level), borderRadius: BorderRadius.circular(11)),
          child: Icon(markIcon(action), color: SL.fg(context, level), size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(number, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('${markLabel(action)}${at > 0 ? ' · ${timeAgo(at)}' : ''}', style: TextStyle(fontSize: 13, color: SL.fg(context, level), fontWeight: FontWeight.w700)),
            if (comment.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(comment, style: TextStyle(fontSize: 13.5, color: cs.onSurface.withAlpha(185))),
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
