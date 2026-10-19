import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/block_sheet.dart';
import '../widgets/common.dart';

/// One sender's conversation: every SMS and call Second Look checked from them, as chat bubbles with their own
/// verdict. Mark the sender (Block / Spam / Fraud / Safe / Comment), call or chat back, open any message's full
/// result, or select messages to delete. Kept only on this phone.
class SenderThreadScreen extends StatefulWidget {
  const SenderThreadScreen({super.key, required this.groupKey, required this.initial, this.whatsApp = false});

  /// [alertGroupKey] of the conversation.
  final String groupKey;

  /// The alerts already loaded (newest first); reloaded when alerts change.
  final List<Map<String, dynamic>> initial;

  /// WhatsApp is installed on this phone.
  final bool whatsApp;

  @override
  State<SenderThreadScreen> createState() => _SenderThreadScreenState();
}

class _SenderThreadScreenState extends State<SenderThreadScreen> {
  late List<Map<String, dynamic>> items = List.of(widget.initial);
  Map<String, dynamic>? _mark;
  bool _markSet = false;
  bool busy = false;
  bool selecting = false;
  final selected = <String>{};
  bool _leaving = false;

  AlertGroup get g => AlertGroup(widget.groupKey, items);
  Map<String, dynamic>? get mark => _markSet ? _mark : g.mark;

  @override
  void initState() {
    super.initState();
    alertsVersion.addListener(_reload);
  }

  @override
  void dispose() {
    alertsVersion.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    List<Map<String, dynamic>> h;
    try {
      h = await Native.instance.history();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final mine = h.where((a) => alertGroupKey(a) == widget.groupKey).toList()..sort((x, y) => alertAt(y).compareTo(alertAt(x)));
    if (mine.isEmpty) {
      _leave();
      return;
    }
    setState(() {
      items = mine;
      selected.removeWhere((id) => !mine.any((a) => '${a['id']}' == id));
    });
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _close();
  }

  /// Closes this screen (also while selecting, and even if another screen was opened on top of it).
  void _close() {
    final route = ModalRoute.of(context);
    if (route == null) return;
    final nav = Navigator.of(context);
    if (route.isCurrent) {
      nav.pop();
    } else {
      nav.removeRoute(route);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(m)));
  }

  // ---- marks (same rules as before: a mark is on the sender, linked to its newest alert)

  Future<void> _markAs(String action) async {
    final number = g.sender;
    if (number.isEmpty || busy) return;
    final m = mark;
    String? comment;
    if (action == 'comment') {
      comment = await showCommentSheet(context, number: number, initial: m?['action'] == 'comment' ? '${m?['comment'] ?? ''}' : '');
      if (comment == null || !mounted) return;
    }
    setState(() => busy = true);
    final id = g.latest['id'] == null ? null : '${g.latest['id']}';
    final ok = await Native.instance.markNumber(number, action, comment: comment, historyId: id);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (ok) {
        _markSet = true;
        _mark = {'action': action, 'comment': comment, 'at': DateTime.now().millisecondsSinceEpoch};
      }
    });
    if (!ok) {
      _snack(tr('Couldn\'t save. Please try again.'));
      return;
    }
    notifyAlertsChanged();
    if (action == 'block') {
      await showBlockedSheet(context, number);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(markDoneText(action)),
      action: action == 'comment'
          ? null
          : SnackBarAction(
              label: tr('Undo'),
              onPressed: () async {
                final undone = await Native.instance.markNumber(number, 'unblock', historyId: id);
                if (!mounted || !undone) return;
                setState(() {
                  _markSet = true;
                  _mark = null;
                });
                notifyAlertsChanged();
              },
            ),
    ));
  }

  Future<void> _chat() async {
    final ok = await Native.instance.openChat(alertChatNumber(g.summary));
    if (!ok) _snack(tr('Couldn\'t open WhatsApp.'));
  }

  Future<void> _more(List<String> keys) async {
    final sender = g.sender;
    final m = mark;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis, style: SL.h(18)),
          ),
          for (final k in keys)
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Icon(_moreIcon(k), color: _moreColor(k)),
              title: Text(_moreLabel(k)),
              trailing: m?['action'] == k ? const Icon(Icons.check_rounded, color: SL.accent) : null,
              onTap: () => Navigator.pop(c, k),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'call':
        Native.instance.dial(sender);
        break;
      case 'sms':
        Native.instance.smsTo(sender, '');
        break;
      case 'chat':
        await _chat();
        break;
      default:
        await _markAs(picked);
    }
  }

  static IconData _moreIcon(String k) => k == 'call' ? Icons.call_outlined : (k == 'sms' ? Icons.sms_outlined : (k == 'chat' ? Icons.chat_outlined : markIcon(k)));
  static Color _moreColor(String k) => k == 'call' || k == 'sms' || k == 'chat' || k == 'comment' ? SL.accent : SL.fgOf(markLevel(k));
  static String _moreLabel(String k) {
    switch (k) {
      case 'call':
        return tr('Call back');
      case 'sms':
        return tr('Send SMS');
      case 'chat':
        return tr('Chat on WhatsApp');
      case 'block':
        return tr('Block');
      default:
        return markLabel(k);
    }
  }

  // ---- selection & delete

  void _toggle(String id) {
    setState(() {
      if (!selected.remove(id)) selected.add(id);
      selecting = selected.isNotEmpty;
    });
  }

  void _startSelect([String? id]) {
    setState(() {
      selecting = true;
      if (id != null) selected.add(id);
    });
  }

  void _endSelect() => setState(() {
        selecting = false;
        selected.clear();
      });

  Future<bool> _confirm(String title, String text) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(text),
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
    return ok == true;
  }

  Future<void> _deleteSelected() async {
    if (selected.isEmpty || busy) return;
    final n = selected.length;
    final ok = await _confirm(
      n == 1 ? tr('Delete 1 item?') : tr('Delete {n} items?', {'n': n}),
      tr('This removes the selected SMS and calls from this phone. Numbers you marked stay marked.'),
    );
    if (!ok || !mounted) return;
    setState(() => busy = true);
    final ids = selected.toList();
    final all = ids.length >= items.length;
    final done = await Native.instance.deleteHistory(ids);
    if (!mounted) return;
    setState(() => busy = false);
    if (done < 0) {
      _snack(tr('Couldn\'t delete. Please try again.'));
      return;
    }
    _snack(tr('Deleted.'));
    if (all) _leaving = true;
    notifyAlertsChanged();
    if (all) {
      _close();
    } else {
      _endSelect();
    }
  }

  Future<void> _deleteConversation() async {
    if (busy) return;
    final ok = await _confirm(
      tr('Delete this conversation?'),
      tr('This removes every SMS and call from this sender from this phone. Numbers you marked stay marked.'),
    );
    if (!ok || !mounted) return;
    setState(() => busy = true);
    final done = await Native.instance.deleteHistory(g.ids);
    if (!mounted) return;
    setState(() => busy = false);
    if (done < 0) {
      _snack(tr('Couldn\'t delete. Please try again.'));
      return;
    }
    _snack(tr('Deleted.'));
    _leaving = true;
    notifyAlertsChanged();
    _close();
  }

  // ---- UI

  @override
  Widget build(BuildContext context) {
    final group = g;
    final who = group.sender.isEmpty ? tr('Unknown sender') : group.sender;
    final allSelected = selected.length == items.length && items.isNotEmpty;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) _endSelect();
      },
      child: Scaffold(
        backgroundColor: SL.ground,
        appBar: AppBar(
          leadingWidth: 60,
          leading: selecting
              ? IconButton(tooltip: tr('Cancel'), onPressed: _endSelect, icon: const Icon(Icons.close_rounded))
              : const Padding(padding: EdgeInsets.only(left: 8), child: Center(child: BackCircle())),
          titleSpacing: 4,
          title: Text(
            selecting ? tr('{n} selected', {'n': selected.length}) : who,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SL.h(selecting ? 20 : 19),
          ),
          actions: selecting
              ? [
                  TextButton(
                    onPressed: () => setState(() {
                      if (allSelected) {
                        selected.clear();
                        selecting = false;
                      } else {
                        selected.addAll(group.ids);
                      }
                    }),
                    child: Text(allSelected ? tr('Select none') : tr('Select all')),
                  ),
                  IconButton(
                    tooltip: tr('Delete'),
                    onPressed: selected.isEmpty || busy ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline_rounded, color: SL.dangerD),
                  ),
                  const SizedBox(width: 6),
                ]
              : [
                  PopupMenuButton<String>(
                    tooltip: tr('More'),
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (v) {
                      if (v == 'select') _startSelect();
                      if (v == 'delete') _deleteConversation();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'select', child: _menuRow(Icons.checklist_rounded, tr('Select messages'), SL.text)),
                      PopupMenuItem(value: 'delete', child: _menuRow(Icons.delete_outline_rounded, tr('Delete conversation'), SL.dangerSoft)),
                    ],
                  ),
                  const SizedBox(width: 8),
                ],
        ),
        body: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: _header(group)),
          Expanded(child: _thread(context)),
          if (!selecting) _actionBar(group),
        ]),
      ),
    );
  }

  static Widget _menuRow(IconData icon, String label, Color color) => Row(children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Flexible(child: Text(label, style: TextStyle(color: color))),
      ]);

  /// The sender, how many messages and calls, and how they were judged.
  Widget _header(AlertGroup group) {
    final level = group.level;
    final m = mark;
    final mAction = '${m?['action'] ?? ''}';
    final mComment = '${m?['comment'] ?? ''}'.trim();
    final danger = group.countOf('danger'), warn = group.countOf('warning');
    final verdicts = <String>[
      if (danger > 0) danger == 1 ? tr('1 looks like a scam') : tr('{n} look like scams', {'n': danger}),
      if (warn > 0) warn == 1 ? tr('1 looks suspicious') : tr('{n} look suspicious', {'n': warn}),
      if (danger == 0 && warn == 0) tr('All look normal'),
    ];
    final fg = SL.fgOf(level);
    return Panel(
      padding: const EdgeInsets.all(14),
      color: level == 'safe' ? SL.glass : fg.withAlpha(16),
      borderColor: level == 'safe' ? SL.glassBorder : fg.withAlpha(90),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SenderAvatar(level: level, sms: group.hasSms, call: group.hasCall, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(alertCountLabel(group.smsCount, group.callCount), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: SL.text)),
              const SizedBox(height: 2),
              Text(verdicts.join(' · '), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: level == 'safe' ? SL.textSecondary : SL.pale(level))),
            ]),
          ),
          const SizedBox(width: 8),
          alertLevelPill(context, level),
        ]),
        if (group.isNew || m != null) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (group.isNew) AlertTag(tr('NEW'), color: SL.accentLight, bg: SL.accent.withAlpha(36)),
            if (m != null) AlertBadge(markLabel(mAction), icon: markIcon(mAction), color: mAction == 'comment' ? SL.accent : SL.fgOf(markLevel(mAction))),
          ]),
        ],
        if (mComment.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.chat_bubble_outline_rounded, size: 15, color: SL.textMuted),
            const SizedBox(width: 6),
            Expanded(child: Text(mComment, style: const TextStyle(fontSize: 13.5, fontStyle: FontStyle.italic, color: SL.textSoft))),
          ]),
        ],
      ]),
    );
  }

  static String _dayKey(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month}-${d.day}';
  }

  String _dayLabel(BuildContext context, int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return tr('Today');
    if (diff == 1) return tr('Yesterday');
    return MaterialLocalizations.of(context).formatMediumDate(d);
  }

  /// Newest at the bottom, like a chat, with a date line where the day changes.
  Widget _thread(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final a = items[i];
      children.add(_bubble(context, a));
      final at = alertAt(a);
      final older = i + 1 < items.length ? alertAt(items[i + 1]) : null;
      if (older == null || _dayKey(older) != _dayKey(at)) children.add(_dayLine(_dayLabel(context, at)));
    }
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      children: children,
    );
  }

  Widget _dayLine(String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          const Expanded(child: Divider(color: SL.hairline)),
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: SL.textMuted)),
            ),
          const Expanded(child: Divider(color: SL.hairline)),
        ]),
      );

  /// One SMS or call as a bubble with its own verdict and time. Tap: the full result; long-press: select.
  Widget _bubble(BuildContext context, Map<String, dynamic> a) {
    final id = '${a['id'] ?? ''}';
    final level = alertLevel(a);
    final call = a['kind'] == 'call';
    final isSel = selected.contains(id);
    final fg = SL.fgOf(level);
    final Color fill, edge;
    if (isSel) {
      fill = SL.accent.withAlpha(24);
      edge = SL.accent;
    } else if (level == 'safe') {
      fill = const Color(0x0FFFFFFF);
      edge = SL.glassBorder;
    } else {
      fill = fg.withAlpha(20);
      edge = fg.withAlpha(level == 'danger' ? 110 : 90);
    }
    final summary = '${a['summary'] ?? ''}'.trim();
    final text = call ? (summary.isNotEmpty ? summary : tr('Incoming call')) : alertPreview(a);
    final own = alertMark(a);
    final ownAction = '${own?['action'] ?? ''}';
    const r = BorderRadius.only(
      topLeft: Radius.circular(6),
      topRight: Radius.circular(18),
      bottomLeft: Radius.circular(18),
      bottomRight: Radius.circular(18),
    );
    final maxW = MediaQuery.sizeOf(context).width * (selecting ? 0.72 : 0.84);
    final bubble = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW > 480 ? 480 : maxW),
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: edge, width: isSel ? 1.5 : 1)),
        child: InkWell(
          borderRadius: r,
          onTap: id.isEmpty ? null : (selecting ? () => _toggle(id) : () => openAlertResult(context, a)),
          onLongPress: id.isEmpty
              ? null
              : () {
                  if (selecting) {
                    _toggle(id);
                  } else {
                    _startSelect(id);
                  }
                },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (call)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.phone_callback_rounded, size: 16, color: fg),
                    const SizedBox(width: 6),
                    Text(tr('Call'), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: fg)),
                  ]),
                ),
              Text(text, style: const TextStyle(fontSize: 14.5, height: 1.4, color: SL.text)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _verdictChip(level),
                if (own != null) AlertBadge(markLabel(ownAction), icon: markIcon(ownAction), color: ownAction == 'comment' ? SL.accent : SL.fgOf(markLevel(ownAction))),
                if (a['test'] == true) AlertTag(tr('Test'), color: SL.textSecondary, bg: const Color(0x14FFFFFF)),
                Text(_clock(context, alertAt(a)), style: const TextStyle(fontSize: 11.5, color: SL.textMuted)),
              ]),
            ]),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (selecting) ...[
          GestureDetector(onTap: id.isEmpty ? null : () => _toggle(id), child: SelectDot(selected: isSel, size: 24)),
          const SizedBox(width: 10),
        ],
        Flexible(child: bubble),
      ]),
    );
  }

  static String _clock(BuildContext context, int ms) {
    if (ms <= 0) return '';
    return MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)));
  }

  Widget _verdictChip(String level) {
    final fg = SL.fgOf(level);
    final label = level == 'danger' ? tr('Scam') : (level == 'warning' ? tr('Suspicious') : tr('OK'));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: fg.withAlpha(30), borderRadius: BorderRadius.circular(10), border: Border.all(color: fg.withAlpha(90))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(SL.mark(level), size: 13, color: fg),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
      ]),
    );
  }

  /// The sender's actions, by the same rules as the alert cards: Block / Spam / Fraud for anything suspicious;
  /// Call back and WhatsApp (when allowed) or SMS for a normal number; Safe / Comment for a normal SMS header.
  Widget _actionBar(AlertGroup group) {
    final sender = group.sender;
    if (sender.isEmpty) return const SizedBox.shrink();
    final level = group.level;
    final bad = level != 'safe';
    final isNumber = group.fromNumber;
    final m = mark;
    final mAction = '${m?['action'] ?? ''}';
    final chat = whatsAppAllowed(group.summary, installed: widget.whatsApp, mark: m);
    VoidCallback? on(VoidCallback f) => busy ? null : f;
    final List<Widget> row;
    final List<String> more;
    if (bad) {
      row = [
        AlertActionButton(label: mAction == 'block' ? tr('Blocked') : tr('Block'), onTap: on(() => _markAs('block')), filled: true),
        AlertActionButton(label: tr('Spam'), onTap: on(() => _markAs('spam')), selected: mAction == 'spam', selColor: SL.warnD),
        AlertActionButton(label: tr('Fraud'), onTap: on(() => _markAs('fraud')), selected: mAction == 'fraud', selColor: SL.dangerD),
      ];
      more = ['safe', 'comment', if (isNumber && level != 'danger') ...['call', 'sms']];
    } else if (isNumber) {
      row = [
        AlertActionButton(label: tr('Call back'), icon: Icons.call_outlined, onTap: on(() => Native.instance.dial(sender))),
        if (chat)
          AlertActionButton(label: tr('Chat on WhatsApp'), onTap: on(_chat), tint: SL.safeD)
        else
          AlertActionButton(label: tr('Send SMS'), onTap: on(() => Native.instance.smsTo(sender, ''))),
      ];
      more = ['block', 'spam', 'fraud', 'safe', 'comment', if (chat) 'sms'];
    } else {
      row = [
        AlertActionButton(label: tr('Safe'), onTap: on(() => _markAs('safe')), selected: mAction == 'safe', selColor: SL.safeD),
        AlertActionButton(label: tr('Comment'), onTap: on(() => _markAs('comment')), selected: mAction == 'comment', selColor: SL.accent),
      ];
      more = ['block', 'spam', 'fraud'];
    }
    return Container(
      decoration: const BoxDecoration(
        color: SL.navFill,
        border: Border(top: BorderSide(color: SL.glassBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              for (final w in row) ...[Expanded(child: w), const SizedBox(width: 8)],
              AlertMoreButton(onTap: busy ? null : () => _more(more)),
            ]),
            if (chat && !bad)
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
                child: Text(tr('Opens WhatsApp; it will tell you if this number isn\'t on WhatsApp.'), style: const TextStyle(fontSize: 12, color: SL.textMuted)),
              ),
          ]),
        ),
      ),
    );
  }
}
