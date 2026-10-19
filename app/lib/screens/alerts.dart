import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../monetize/monetize.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import 'sender_thread.dart';
import 'shield_health.dart';

/// Every SMS and call Second Look checked (kept only on this phone), grouped by sender, with the history of marks.
/// Long-press a conversation (or tap Select) to choose conversations to delete.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, this.asPage = false, this.startSelecting = false});

  /// Opened from Me → "Choose what to delete" (a page with a back button) rather than as a tab.
  final bool asPage;

  /// Start in selection mode.
  final bool startSelecting;

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
  bool busy = false;

  /// Selection mode: the chosen conversations (by [alertGroupKey]).
  late bool selecting = widget.startSelecting;
  final selected = <String>{};

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
      // Forget selected conversations that no longer exist.
      final keys = {for (final a in h) alertGroupKey(a)};
      selected.removeWhere((k) => !keys.contains(k));
    });
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
    if (!mounted) return;
    setState(() {
      selecting = false;
      selected.clear();
    });
    notifyAlertsChanged(); // reloads this list, Home and any open conversation
  }

  // ---- selection

  void _startSelect([String? key]) {
    setState(() {
      selecting = true;
      if (filter == 'marked') filter = 'all';
      if (key != null) selected.add(key);
    });
  }

  void _endSelect() => setState(() {
        selecting = false;
        selected.clear();
      });

  void _toggle(String key) => setState(() {
        if (!selected.remove(key)) selected.add(key);
      });

  Future<void> _deleteSelected(List<AlertGroup> groups) async {
    final chosen = groups.where((g) => selected.contains(g.key)).toList();
    if (chosen.isEmpty || busy) return;
    final ids = [for (final g in chosen) ...g.ids];
    final n = chosen.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(n == 1 ? tr('Delete 1 conversation?') : tr('Delete {n} conversations?', {'n': n})),
        content: Text(tr('This removes the selected SMS and calls from this phone. Numbers you marked stay marked.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: SL.dangerD, foregroundColor: SL.onDanger),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    final done = await Native.instance.deleteHistory(ids);
    if (!mounted) return;
    setState(() => busy = false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (done < 0) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Couldn\'t delete. Please try again.'))));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(tr('Deleted.'))));
    _endSelect();
    notifyAlertsChanged();
  }

  Future<void> _openGroup(AlertGroup g) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SenderThreadScreen(groupKey: g.key, initial: g.items, whatsApp: whatsApp),
    ));
    if (mounted) load();
  }

  List<AlertGroup> _shownGroups() {
    final groups = groupAlerts(items);
    switch (filter) {
      case 'danger':
        return groups.where((g) => g.level == 'danger').toList();
      case 'call':
        return groups.where((g) => g.hasCall).toList();
      default:
        return groups;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final groups = groupAlerts(items);
    final danger = groups.where((g) => g.level == 'danger').length;
    final shown = filter == 'marked' ? <AlertGroup>[] : _shownGroups();
    // Inside the tab bar, only the visible tab may hold back the system back button.
    final visible = TickerMode.of(context);
    return PopScope(
      canPop: !(selecting && visible),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) _endSelect();
      },
      child: Scaffold(
        backgroundColor: widget.asPage ? SL.ground : Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 24), children: [
              if (selecting) _selectHeader(shown) else _header(),
              const SizedBox(height: 14),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _filter('all', tr('All')),
                  _filter('danger', danger > 0 ? '${tr('Danger')} $danger' : tr('Danger')),
                  _filter('call', tr('Calls')),
                  if (!selecting) _filter('marked', tr('Marked')),
                ]),
              ),
              const SizedBox(height: 14),
              if (selecting && shown.isNotEmpty) ...[
                Text(tr('Tap conversations to choose them, then tap Delete.'), style: const TextStyle(fontSize: 13, color: SL.textMuted)),
                const SizedBox(height: 10),
              ],
              if (filter == 'marked') ..._marksList(context) else ..._alertsList(context, shown),
            ]),
          ),
        ),
      ),
    );
  }

  /// "Alerts", refresh, Select and ⋯ (Select, Delete all).
  Widget _header() => Row(children: [
        if (widget.asPage) ...[const BackCircle(), const SizedBox(width: 12)],
        Expanded(child: Text(tr('Alerts'), maxLines: 1, overflow: TextOverflow.ellipsis, style: SL.h(28))),
        _RoundIcon(icon: Icons.refresh_rounded, tooltip: tr('Refresh'), onTap: load),
        if (items.isNotEmpty) ...[
          const SizedBox(width: 4),
          TextButton(onPressed: () => _startSelect(), child: Text(tr('Select'))),
          PopupMenuButton<String>(
            tooltip: tr('More'),
            icon: const Icon(Icons.more_vert_rounded, color: SL.text),
            onSelected: (v) {
              if (v == 'select') _startSelect();
              if (v == 'clear') _clearAll();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'select', child: _menuRow(Icons.checklist_rounded, tr('Select'), SL.text)),
              PopupMenuItem(value: 'clear', child: _menuRow(Icons.delete_sweep_outlined, tr('Delete all'), SL.dangerSoft)),
            ],
          ),
        ],
      ]);

  static Widget _menuRow(IconData icon, String label, Color color) => Row(children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Flexible(child: Text(label, style: TextStyle(color: color))),
      ]);

  /// Selection mode: ✕, "3 selected", Select all, Delete.
  Widget _selectHeader(List<AlertGroup> shown) {
    final allOn = shown.isNotEmpty && shown.every((g) => selected.contains(g.key));
    return Row(children: [
      _RoundIcon(icon: Icons.close_rounded, tooltip: tr('Cancel'), onTap: _endSelect),
      const SizedBox(width: 12),
      Expanded(
        child: Text(tr('{n} selected', {'n': selected.length}), maxLines: 1, overflow: TextOverflow.ellipsis, style: SL.h(22)),
      ),
      TextButton(
        onPressed: shown.isEmpty
            ? null
            : () => setState(() {
                  if (allOn) {
                    for (final g in shown) {
                      selected.remove(g.key);
                    }
                  } else {
                    selected.addAll(shown.map((g) => g.key));
                  }
                }),
        child: Text(allOn ? tr('Select none') : tr('Select all')),
      ),
      const SizedBox(width: 4),
      Tooltip(
        message: tr('Delete'),
        child: Material(
          color: selected.isEmpty ? Colors.transparent : SL.dangerD,
          shape: CircleBorder(side: BorderSide(color: selected.isEmpty ? const Color(0x2E8CDCFF) : SL.dangerD)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: selected.isEmpty || busy ? null : () => _deleteSelected(groupAlerts(items)),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.delete_outline_rounded, size: 21, color: selected.isEmpty ? SL.textMuted : SL.onDanger),
            ),
          ),
        ),
      ),
    ]);
  }

  List<Widget> _alertsList(BuildContext context, List<AlertGroup> shown) {
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
            if (_phone && !selecting) ...[
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
    // A sponsored card after every 8 conversations (only when one loads). Not while choosing what to delete.
    final ads = !widget.asPage && !selecting;
    return [
      for (final (i, g) in shown.indexed) ...[
        AlertGroupCard(
          key: ValueKey(g.key),
          group: g,
          selecting: selecting,
          selected: selected.contains(g.key),
          onTap: () {
            if (selecting) {
              _toggle(g.key);
            } else {
              _openGroup(g);
            }
          },
          onLongPress: () {
            if (selecting) {
              _toggle(g.key);
            } else {
              _startSelect(g.key);
            }
          },
        ),
        const SizedBox(height: 12),
        if (ads && (i + 1) % 8 == 0) NativeAdCard(key: ValueKey('ad-${(i + 1) ~/ 8}'), margin: const EdgeInsets.only(bottom: 12)),
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
