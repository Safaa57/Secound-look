import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../screens/result.dart';
import '../theme.dart';
import 'common.dart';

/// Bumped whenever alerts may have changed (a test alert, a mark, switching to the Alerts tab).
final alertsVersion = ValueNotifier<int>(0);
void notifyAlertsChanged() => alertsVersion.value++;

/// The sender of an alert as received (phone number or SMS header like "VK-ALERTS").
String alertSender(Map<String, dynamic> a) {
  final n = '${a['number'] ?? ''}'.trim();
  return n.isNotEmpty ? n : '${a['title'] ?? ''}'.trim();
}

/// True when the sender is a phone number (not an SMS header).
bool alertFromNumber(Map<String, dynamic> a) {
  final t = a['senderType'];
  if (t == 'number') return true;
  if (t == 'header') return false;
  final n = '${a['number'] ?? ''}'.replaceAll(RegExp(r'[\s\-()]'), '');
  return RegExp(r'^\+?\d{7,15}$').hasMatch(n);
}

/// The user's mark on an alert, or null. An "unblock" (undo) counts as no mark.
Map<String, dynamic>? alertMark(Map<String, dynamic> a) {
  final u = a['userAction'];
  if (u is! Map) return null;
  final m = u.cast<String, dynamic>();
  final action = '${m['action'] ?? ''}';
  if (action.isEmpty || action == 'unblock') return null;
  return m;
}

String markLabel(String action) {
  switch (action) {
    case 'block':
      return tr('Blocked');
    case 'spam':
      return tr('Spam');
    case 'fraud':
      return tr('Fraud');
    case 'safe':
      return tr('Safe');
    case 'comment':
      return tr('Comment');
    case 'unblock':
      return tr('Mark removed');
    default:
      return action;
  }
}

IconData markIcon(String action) {
  switch (action) {
    case 'block':
      return Icons.block_rounded;
    case 'spam':
      return Icons.campaign_rounded;
    case 'fraud':
      return Icons.gpp_bad_rounded;
    case 'safe':
      return Icons.verified_rounded;
    case 'comment':
      return Icons.chat_bubble_outline_rounded;
    default:
      return Icons.undo_rounded;
  }
}

String markLevel(String action) => action == 'safe' || action == 'comment' || action == 'unblock' ? 'safe' : (action == 'spam' ? 'warning' : 'danger');

int _ms(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

void _openResult(BuildContext context, Map<String, dynamic> a) {
  final r = (a['result'] as Map?)?.cast<String, dynamic>();
  if (r != null) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(result: r, title: a['title'] as String? ?? 'Alert')));
}

Widget _levelPill(BuildContext context, String level) =>
    Pill(level == 'danger' ? tr('Scam') : level == 'warning' ? tr('Suspicious') : tr('OK'), fg: SL.fg(context, level), bg: SL.bg(context, level));

/// A small grey or coloured badge ("New sender", "Test").
class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.icon, this.color});
  final String text;
  final IconData? icon;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withAlpha(26), borderRadius: BorderRadius.circular(999), border: Border.all(color: c.withAlpha(70))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: c), const SizedBox(width: 4)],
        Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c)),
      ]),
    );
  }
}

/// One alert in a short list (Home).
class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.a});
  final Map<String, dynamic> a;
  @override
  Widget build(BuildContext context) {
    final level = a['level'] as String? ?? 'safe';
    final sender = alertSender(a);
    return Panel(
      padding: const EdgeInsets.all(14),
      onTap: () => _openResult(context, a),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: SL.bg(context, level), borderRadius: BorderRadius.circular(12)),
          child: Icon(a['kind'] == 'call' ? Icons.call_rounded : Icons.sms_rounded, color: SL.fg(context, level)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sender.isEmpty ? '${a['title'] ?? ''}' : sender, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${a['summary'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(160))),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          _levelPill(context, level),
          const SizedBox(height: 4),
          Text(timeAgo(_ms(a['at'])), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withAlpha(130))),
        ]),
      ]),
    );
  }
}

/// One alert in the Alerts tab, with quick actions: Block, Spam, Fraud, Safe, Comment, and call / SMS / chat back.
class AlertCard extends StatefulWidget {
  const AlertCard({super.key, required this.a, this.whatsApp = false, this.onChanged});
  final Map<String, dynamic> a;

  /// WhatsApp is installed on this phone.
  final bool whatsApp;
  final VoidCallback? onChanged;

  @override
  State<AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends State<AlertCard> {
  Map<String, dynamic>? mark;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    mark = alertMark(widget.a);
  }

  @override
  void didUpdateWidget(AlertCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.a, widget.a)) mark = alertMark(widget.a);
  }

  Future<void> _mark(String action) async {
    final number = alertSender(widget.a);
    if (number.isEmpty || busy) return;
    String? comment;
    if (action == 'comment') {
      comment = await showCommentSheet(context, number: number, initial: mark?['action'] == 'comment' ? '${mark?['comment'] ?? ''}' : '');
      if (comment == null || !mounted) return;
    }
    setState(() => busy = true);
    final id = widget.a['id'] == null ? null : '${widget.a['id']}';
    final ok = await Native.instance.markNumber(number, action, comment: comment, historyId: id);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (ok) mark = {'action': action, 'comment': comment, 'at': DateTime.now().millisecondsSinceEpoch};
    });
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Couldn\'t save. Please try again.'))));
      return;
    }
    widget.onChanged?.call();
    messenger.showSnackBar(SnackBar(
      content: Text(_doneText(action)),
      action: action == 'comment'
          ? null
          : SnackBarAction(
              label: tr('Undo'),
              onPressed: () async {
                final undone = await Native.instance.markNumber(number, 'unblock', historyId: id);
                if (!mounted || !undone) return;
                setState(() => mark = null);
                widget.onChanged?.call();
              },
            ),
    ));
  }

  static String _doneText(String action) {
    switch (action) {
      case 'block':
        return tr('Blocked. When Call Shield is on, calls from this number are rejected, and its SMS won\'t notify you.');
      case 'spam':
        return tr('Marked as spam.');
      case 'fraud':
        return tr('Marked as fraud. Call Shield will warn you if it calls again.');
      case 'safe':
        return tr('Marked as safe.');
      default:
        return tr('Comment saved on this phone.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
    final cs = Theme.of(context).colorScheme;
    final level = a['level'] as String? ?? 'safe';
    final call = a['kind'] == 'call';
    final sender = alertSender(a);
    final isNumber = alertFromNumber(a);
    final preview = '${a['preview'] ?? ''}'.trim();
    final summary = '${a['summary'] ?? ''}'.trim();
    final m = mark;
    final mAction = '${m?['action'] ?? ''}';
    final mComment = '${m?['comment'] ?? ''}'.trim();
    final muted = cs.onSurface.withAlpha(150);

    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openResult(context, a),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: SL.bg(context, level), borderRadius: BorderRadius.circular(12)),
                child: Icon(call ? Icons.call_rounded : Icons.sms_rounded, color: SL.fg(context, level)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(sender.isEmpty ? tr('Unknown sender') : sender,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                  const SizedBox(height: 2),
                  Text('${call ? tr('Call') : 'SMS'} · ${timeAgo(_ms(a['at']))}', style: TextStyle(fontSize: 12.5, color: muted)),
                ]),
              ),
              const SizedBox(width: 8),
              _levelPill(context, level),
            ]),
            if (a['firstTime'] == true || a['test'] == true || m != null) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (a['firstTime'] == true) _Badge(tr('New sender'), icon: Icons.fiber_new_rounded),
                if (a['test'] == true) _Badge(tr('Test'), icon: Icons.science_rounded, color: muted),
                if (m != null) _Badge(markLabel(mAction), icon: markIcon(mAction), color: SL.fg(context, markLevel(mAction))),
              ]),
            ],
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: cs.onSurface.withAlpha(12), borderRadius: BorderRadius.circular(12)),
                child: Text(preview, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.4)),
              ),
            ],
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: cs.onSurface.withAlpha(175))),
            ],
            if (mComment.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.chat_bubble_outline_rounded, size: 15, color: muted),
                const SizedBox(width: 6),
                Expanded(child: Text(mComment, style: TextStyle(fontSize: 13.5, fontStyle: FontStyle.italic, color: cs.onSurface.withAlpha(190)))),
              ]),
            ],
          ]),
        ),
        if (sender.isNotEmpty) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _chip('block', tr('Block'), Icons.block_rounded, 'danger'),
              _chip('spam', tr('Spam'), Icons.campaign_rounded, 'warning'),
              _chip('fraud', tr('Fraud'), Icons.gpp_bad_rounded, 'danger'),
              _chip('safe', tr('Safe'), Icons.verified_rounded, 'safe'),
              _chip('comment', tr('Comment'), Icons.edit_note_rounded, null),
            ]),
          ),
        ],
        if (isNumber && level != 'danger' && sender.isNotEmpty) ...[
          Wrap(spacing: 4, children: [
            TextButton.icon(
              onPressed: () => Native.instance.dial(sender),
              icon: const Icon(Icons.call_rounded, size: 18),
              label: Text(tr('Call')),
            ),
            TextButton.icon(
              onPressed: () => Native.instance.smsTo(sender, ''),
              icon: const Icon(Icons.sms_rounded, size: 18),
              label: Text(tr('Send SMS')),
            ),
            if (call && widget.whatsApp)
              TextButton.icon(
                onPressed: () async {
                  final ok = await Native.instance.openChat(sender);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t open WhatsApp.'))));
                  }
                },
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: Text(tr('Chat on WhatsApp')),
              ),
          ]),
          if (call && widget.whatsApp)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Text(tr('Opens WhatsApp; it will tell you if this number isn\'t on WhatsApp.'), style: TextStyle(fontSize: 12, color: muted)),
            ),
        ],
      ]),
    );
  }

  Widget _chip(String action, String label, IconData icon, String? level) {
    final selected = mark?['action'] == action;
    final c = level == null ? Theme.of(context).colorScheme.primary : SL.fg(context, level);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        avatar: Icon(icon, size: 17, color: c),
        label: Text(label),
        side: BorderSide(color: selected ? c : c.withAlpha(60)),
        backgroundColor: selected ? c.withAlpha(30) : null,
        labelStyle: TextStyle(fontWeight: FontWeight.w700, color: c),
        visualDensity: VisualDensity.compact,
        onPressed: busy ? null : () => _mark(action),
      ),
    );
  }
}

/// Asks for a short note about a number (max 200 characters). Null if cancelled.
Future<String?> showCommentSheet(BuildContext context, {required String number, String initial = ''}) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CommentSheet(number: number, initial: initial),
    );

class _CommentSheet extends StatefulWidget {
  const _CommentSheet({required this.number, required this.initial});
  final String number, initial;
  @override
  State<_CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<_CommentSheet> {
  late final TextEditingController text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void _save() {
    final t = text.text.trim();
    if (t.isEmpty) return;
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Add a comment'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(widget.number, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(150))),
          const SizedBox(height: 12),
          TextField(
            controller: text,
            autofocus: true,
            maxLength: 200,
            maxLines: 3,
            minLines: 2,
            inputFormatters: [LengthLimitingTextInputFormatter(200)],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(hintText: tr('e.g. Delivery person, asked for OTP, bank called about loan')),
          ),
          Text(tr('Saved only on this phone.'), style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(140))),
          const SizedBox(height: 12),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: text,
            builder: (context, v, _) => FilledButton(onPressed: v.text.trim().isEmpty ? null : _save, child: Text(tr('Save'))),
          ),
        ]),
      );
}
