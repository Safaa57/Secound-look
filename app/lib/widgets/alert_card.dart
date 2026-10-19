import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../screens/result.dart';
import '../theme.dart';
import 'block_sheet.dart';
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

/// The phone-number facts the engine found for this alert's sender (numberDetails for calls, sender.number for SMS).
Map<String, dynamic>? alertNumberDetails(Map<String, dynamic> a) {
  final r = a['result'];
  if (r is! Map) return null;
  final info = r['info'];
  if (info is! Map) return null;
  final nd = info['numberDetails'];
  if (nd is Map) return nd.cast<String, dynamic>();
  final sender = info['sender'];
  if (sender is Map && sender['number'] is Map) return (sender['number'] as Map).cast<String, dynamic>();
  return null;
}

/// Whether to offer "Chat on WhatsApp" for an alert. All must hold: WhatsApp is installed; the sender is a phone
/// number (not an SMS header); the lookup says it's a valid MOBILE number (or FIXED_LINE_OR_MOBILE outside India);
/// it isn't a 140 / 1600 series, toll-free or short code (under 8 digits); the verdict is safe; and the user
/// hasn't marked it block, spam or fraud.
bool whatsAppAllowed(Map<String, dynamic> a, {required bool installed, Map<String, dynamic>? mark}) {
  if (!installed || !alertFromNumber(a)) return false;
  if ('${a['level'] ?? 'safe'}' != 'safe') return false;
  final act = '${mark?['action'] ?? ''}';
  if (act == 'block' || act == 'spam' || act == 'fraud') return false;
  final d = alertNumberDetails(a);
  if (d == null || d['valid'] != true) return false;
  final e164 = '${d['e164'] ?? ''}';
  final digits = e164.replaceAll(RegExp(r'\D'), '');
  final senderDigits = alertSender(a).replaceAll(RegExp(r'\D'), '');
  if (digits.length < 8 || senderDigits.length < 8) return false;
  final india = '${d['country'] ?? ''}' == 'IN' || e164.startsWith('+91');
  final type = '${d['type'] ?? ''}';
  if (!(type == 'MOBILE' || (type == 'FIXED_LINE_OR_MOBILE' && !india))) return false;
  final series = '${d['series'] ?? ''}'.toLowerCase();
  if (series.startsWith('140') || series.startsWith('1600') || series.contains('toll')) return false;
  if (india) {
    final nsn = digits.startsWith('91') ? digits.substring(2) : digits;
    if (nsn.startsWith('140') || nsn.startsWith('1600') || nsn.startsWith('1800') || nsn.startsWith('1860')) return false;
  }
  return true;
}

/// The number to open a chat with: the full international form when the lookup has it.
String alertChatNumber(Map<String, dynamic> a) {
  final e = '${alertNumberDetails(a)?['e164'] ?? ''}';
  return e.startsWith('+') ? e : alertSender(a);
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

/// The snack bar text after marking a number.
String markDoneText(String action) {
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

int _ms(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

void openAlertResult(BuildContext context, Map<String, dynamic> a) {
  final r = (a['result'] as Map?)?.cast<String, dynamic>();
  if (r != null) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(result: r, title: a['title'] as String? ?? 'Alert')));
}

Widget alertLevelPill(BuildContext context, String level) => Pill(level == 'danger' ? tr('Scam') : level == 'warning' ? tr('Suspicious') : tr('OK'),
    icon: SL.mark(level), fg: SL.fg(context, level), bg: SL.bg(context, level));

/// A small grey or coloured badge ("New sender", "Test").
class AlertBadge extends StatelessWidget {
  const AlertBadge(this.text, {this.icon, this.color});
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
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      onTap: () => openAlertResult(context, a),
      child: Row(children: [
        IconTile(a['kind'] == 'call' ? Icons.call_rounded : Icons.sms_rounded, color: SL.fg(context, level), size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sender.isEmpty ? '${a['title'] ?? ''}' : sender, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 2),
            Text('${a['summary'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withAlpha(160))),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          alertLevelPill(context, level),
          const SizedBox(height: 4),
          Text(timeAgo(_ms(a['at'])), style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurface.withAlpha(130))),
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
    if (action == 'block') {
      await showBlockedSheet(context, number);
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(markDoneText(action)),
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

  /// Clock time for today's alerts ("9:41 am"), otherwise "2 d ago".
  String _when(BuildContext context, int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(d));
    }
    return timeAgo(ms);
  }

  Future<void> _chat() async {
    final ok = await Native.instance.openChat(alertChatNumber(widget.a));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t open WhatsApp.'))));
    }
  }

  /// "⋯": the marks and call-backs that aren't already on the card.
  Future<void> _more(List<String> keys) async {
    final sender = alertSender(widget.a);
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
              trailing: mark?['action'] == k ? const Icon(Icons.check_rounded, color: SL.accent) : null,
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
        await _mark(picked);
    }
  }

  static IconData _moreIcon(String k) => k == 'call' ? Icons.call_outlined : (k == 'sms' ? Icons.sms_outlined : (k == 'chat' ? Icons.chat_outlined : markIcon(k)));
  static Color _moreColor(String k) => k == 'call' || k == 'sms' || k == 'chat' ? SL.accent : (k == 'comment' ? SL.accent : SL.fgOf(markLevel(k)));
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

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
    final raw = '${a['level'] ?? 'safe'}';
    final level = raw == 'danger' || raw == 'warning' ? raw : 'safe';
    final bad = level != 'safe';
    final call = a['kind'] == 'call';
    final sender = alertSender(a);
    final isNumber = alertFromNumber(a);
    final preview = '${a['preview'] ?? ''}'.trim();
    final summary = '${a['summary'] ?? ''}'.trim();
    final m = mark;
    final mAction = '${m?['action'] ?? ''}';
    final mComment = '${m?['comment'] ?? ''}'.trim();
    final chat = whatsAppAllowed(a, installed: widget.whatsApp, mark: m);

    final fg = SL.fgOf(level);
    final Color fill, edge, disc;
    switch (level) {
      case 'danger':
        fill = fg.withAlpha(18);
        edge = fg.withAlpha(102);
        disc = fg.withAlpha(46);
        break;
      case 'warning':
        fill = fg.withAlpha(15);
        edge = fg.withAlpha(89);
        disc = fg.withAlpha(41);
        break;
      default:
        fill = SL.glass;
        edge = SL.glassBorder;
        disc = fg.withAlpha(36);
    }
    final who = sender.isEmpty ? tr('Unknown sender') : sender;
    final title = bad ? '$who · ${level == 'danger' ? tr('Likely scam') : tr('Suspicious')}' : who;
    final line = preview.isNotEmpty ? preview : (summary.isNotEmpty ? summary : (call ? tr('Call') : 'SMS'));
    final r = BorderRadius.circular(20);

    // The inline buttons, and what goes behind "⋯".
    Widget? actions;
    if (sender.isNotEmpty) {
      final List<Widget> row;
      final List<String> more;
      if (bad) {
        row = [
          _btn(mAction == 'block' ? tr('Blocked') : tr('Block'), () => _mark('block'), filled: true),
          _btn(tr('Spam'), () => _mark('spam'), selected: mAction == 'spam', selColor: SL.warnD),
          _btn(tr('Fraud'), () => _mark('fraud'), selected: mAction == 'fraud', selColor: SL.dangerD),
        ];
        more = ['safe', 'comment', if (isNumber && level != 'danger') ...['call', 'sms']];
      } else if (isNumber) {
        row = [
          _btn(tr('Call back'), () => Native.instance.dial(sender)),
          if (chat) _btn(tr('Chat on WhatsApp'), _chat, tint: SL.safeD) else _btn(tr('Send SMS'), () => Native.instance.smsTo(sender, '')),
        ];
        more = ['block', 'spam', 'fraud', 'safe', 'comment', if (chat) 'sms'];
      } else {
        row = [
          _btn(tr('Safe'), () => _mark('safe'), selected: mAction == 'safe', selColor: SL.safeD),
          _btn(tr('Comment'), () => _mark('comment'), selected: mAction == 'comment', selColor: SL.accent),
        ];
        more = ['block', 'spam', 'fraud'];
      }
      actions = Row(children: [
        for (final w in row) ...[Expanded(child: w), const SizedBox(width: 8)],
        _moreButton(() => _more(more)),
      ]);
    }

    return Material(
      color: fill,
      shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: edge)),
      child: InkWell(
        borderRadius: r,
        onTap: () => openAlertResult(context, a),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: disc, shape: BoxShape.circle),
                child: Icon(bad ? (call ? Icons.phone_outlined : Icons.chat_bubble_outline_rounded) : Icons.check_rounded, size: 22, color: fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: SL.text))),
                    if (a['firstTime'] == true) ...[const SizedBox(width: 8), AlertTag(tr('NEW'), color: SL.accentLight, bg: SL.accent.withAlpha(36))],
                    if (a['test'] == true) ...[const SizedBox(width: 6), AlertTag(tr('Test'), color: SL.textSecondary, bg: const Color(0x14FFFFFF))],
                  ]),
                  const SizedBox(height: 2),
                  Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: SL.textSoft)),
                ]),
              ),
              const SizedBox(width: 8),
              Text(_when(context, _ms(a['at'])), style: const TextStyle(fontSize: 12, color: SL.textMuted)),
            ]),
            if (m != null && (mAction != 'block' || !bad)) ...[
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: AlertBadge(markLabel(mAction), icon: markIcon(mAction), color: SL.fgOf(markLevel(mAction)))),
            ],
            if (mComment.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.chat_bubble_outline_rounded, size: 15, color: SL.textMuted),
                const SizedBox(width: 6),
                Expanded(child: Text(mComment, style: const TextStyle(fontSize: 13.5, fontStyle: FontStyle.italic, color: SL.textSoft))),
              ]),
            ],
            if (actions != null) ...[const SizedBox(height: 10), actions],
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

  /// A 44 px card button: red filled (Block), quiet outlined, green-tinted (WhatsApp) or highlighted when chosen.
  Widget _btn(String label, VoidCallback onTap, {bool filled = false, Color? tint, bool selected = false, Color? selColor}) {
    final r = BorderRadius.circular(12);
    final Color fill;
    final Color edge;
    final Color text;
    if (filled) {
      fill = SL.dangerD;
      edge = SL.dangerD;
      text = SL.onDanger;
    } else if (tint != null) {
      fill = tint.withAlpha(26);
      edge = tint.withAlpha(115);
      text = SL.pale('safe');
    } else if (selected && selColor != null) {
      fill = selColor.withAlpha(36);
      edge = selColor;
      text = SL.text;
    } else {
      fill = const Color(0x0AFFFFFF);
      edge = const Color(0x2EFFFFFF);
      text = SL.text;
    }
    return Material(
      color: fill,
      shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: edge)),
      child: InkWell(
        borderRadius: r,
        onTap: busy ? null : onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: text)),
          ),
        ),
      ),
    );
  }

  Widget _moreButton(VoidCallback onTap) {
    final r = BorderRadius.circular(12);
    return Tooltip(
      message: tr('More'),
      child: Material(
        color: const Color(0x0AFFFFFF),
        shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: Color(0x2EFFFFFF))),
        child: InkWell(
          borderRadius: r,
          onTap: busy ? null : onTap,
          child: const SizedBox(width: 44, height: 44, child: Icon(Icons.more_horiz_rounded, size: 20, color: SL.text)),
        ),
      ),
    );
  }
}

/// A tiny label next to the sender ("NEW", "Test").
class AlertTag extends StatelessWidget {
  const AlertTag(this.text, {required this.color, required this.bg});
  final String text;
  final Color color, bg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      );
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

// ---------------------------------------------------------------------------------------------------------------
// Alerts grouped by sender: many SMS (and calls) from the same number or SMS header show as one conversation.

/// Clock time for today's alerts ("9:41 am"), otherwise "2 d ago".
String alertWhen(BuildContext context, int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(d));
  }
  return timeAgo(ms);
}

/// The time of an alert in milliseconds (0 if unknown).
int alertAt(Map<String, dynamic> a) => _ms(a['at']);

/// 'safe' | 'warning' | 'danger' for an alert.
String alertLevel(Map<String, dynamic> a) {
  final raw = '${a['level'] ?? 'safe'}';
  return raw == 'danger' || raw == 'warning' ? raw : 'safe';
}

int _rank(String level) => level == 'danger' ? 2 : (level == 'warning' ? 1 : 0);

/// Which conversation an alert belongs to. Phone numbers match on their last 10 digits (so +91 98xx…, 098xx… and
/// 98xx… are the same sender); SMS headers match ignoring case and spaces. SMS and calls from one number share a group.
String alertGroupKey(Map<String, dynamic> a) {
  final sender = alertSender(a);
  if (sender.isEmpty) return 'id:${a['id'] ?? a['at'] ?? ''}';
  if (alertFromNumber(a)) {
    final e164 = '${alertNumberDetails(a)?['e164'] ?? ''}';
    final digits = (e164.isNotEmpty ? e164 : sender).replaceAll(RegExp(r'\D'), '');
    if (digits.isNotEmpty) return 'n:${digits.length > 10 ? digits.substring(digits.length - 10) : digits}';
  }
  return 'h:${sender.toLowerCase().replaceAll(RegExp(r'\s+'), '')}';
}

/// One sender's alerts, newest first.
class AlertGroup {
  AlertGroup(this.key, this.items);
  final String key;
  final List<Map<String, dynamic>> items;

  Map<String, dynamic> get latest => items.first;

  /// The sender as received on the newest alert.
  String get sender => alertSender(latest);
  bool get fromNumber => alertFromNumber(latest);
  int get at => alertAt(latest);
  int get count => items.length;
  int get smsCount => items.where((a) => a['kind'] != 'call').length;
  int get callCount => items.where((a) => a['kind'] == 'call').length;
  bool get hasCall => callCount > 0;
  bool get hasSms => smsCount > 0;
  bool get isTest => items.any((a) => a['test'] == true);
  List<String> get ids => [for (final a in items) if (a['id'] != null) '${a['id']}'];

  /// The worst verdict in the conversation.
  String get level {
    var best = 'safe';
    for (final a in items) {
      final l = alertLevel(a);
      if (_rank(l) > _rank(best)) best = l;
    }
    return best;
  }

  int countOf(String level) => items.where((a) => alertLevel(a) == level).length;

  /// "NEW": the first alert from this sender was the first time Second Look saw it.
  bool get isNew => items.last['firstTime'] == true;

  /// The newest mark the user gave this sender (on any of its alerts), or null.
  Map<String, dynamic>? get mark {
    Map<String, dynamic>? best;
    var bestAt = -1;
    for (final a in items) {
      final u = a['userAction'];
      if (u is! Map) continue;
      final t = _ms(u['at']);
      if (t > bestAt) {
        bestAt = t;
        best = u.cast<String, dynamic>();
      }
    }
    final act = '${best?['action'] ?? ''}';
    if (act.isEmpty || act == 'unblock') return null;
    return best;
  }

  /// The alert used for the sender's number facts (the newest one that has them).
  Map<String, dynamic> get numberSource => items.firstWhere((a) => alertNumberDetails(a) != null, orElse: () => latest);

  /// The newest alert, with the conversation's worst verdict (for rules like the WhatsApp button).
  Map<String, dynamic> get summary => {...numberSource, 'level': level, 'number': latest['number'], 'senderType': latest['senderType'], 'title': latest['title']};

  /// A short line: the newest SMS preview, or what the newest call was.
  String get previewLine => alertPreview(latest);
}

/// The text shown for one alert: the SMS preview, else the summary, else "Call" / "SMS".
String alertPreview(Map<String, dynamic> a) {
  final preview = '${a['preview'] ?? ''}'.trim();
  if (preview.isNotEmpty) return preview;
  final summary = '${a['summary'] ?? ''}'.trim();
  if (summary.isNotEmpty) return summary;
  return a['kind'] == 'call' ? tr('Call') : 'SMS';
}

/// Groups alerts by sender. Newest conversation first; each group's alerts newest first.
List<AlertGroup> groupAlerts(List<Map<String, dynamic>> items) {
  final map = <String, List<Map<String, dynamic>>>{};
  for (final a in items) {
    map.putIfAbsent(alertGroupKey(a), () => []).add(a);
  }
  final groups = <AlertGroup>[];
  map.forEach((k, v) {
    v.sort((x, y) => alertAt(y).compareTo(alertAt(x)));
    groups.add(AlertGroup(k, v));
  });
  groups.sort((x, y) => y.at.compareTo(x.at));
  return groups;
}

/// "5 messages", "2 calls" or "3 messages · 1 call".
String alertCountLabel(int sms, int calls) {
  final m = sms == 1 ? tr('1 message') : tr('{n} messages', {'n': sms});
  final c = calls == 1 ? tr('1 call') : tr('{n} calls', {'n': calls});
  if (calls == 0) return m;
  if (sms == 0) return c;
  return '$m · $c';
}

/// The round avatar of a conversation: the SMS / call icon (both when mixed) in the worst verdict's colour.
class SenderAvatar extends StatelessWidget {
  const SenderAvatar({super.key, required this.level, required this.sms, required this.call, this.size = 48});
  final String level;
  final bool sms, call;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fg = SL.fgOf(level);
    final disc = fg.withAlpha(level == 'safe' ? 36 : 46);
    final both = sms && call;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: disc,
        shape: BoxShape.circle,
        border: Border.all(color: fg.withAlpha(level == 'safe' ? 60 : 110)),
        boxShadow: level == 'danger' ? [BoxShadow(color: fg.withAlpha(60), blurRadius: 16)] : null,
      ),
      child: both
          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.chat_bubble_outline_rounded, size: size * 0.32, color: fg),
              SizedBox(width: size * 0.04),
              Icon(Icons.phone_outlined, size: size * 0.32, color: fg),
            ])
          : Icon(call ? Icons.phone_outlined : Icons.chat_bubble_outline_rounded, size: size * 0.46, color: fg),
    );
  }
}

/// A round check for selection mode.
class SelectDot extends StatelessWidget {
  const SelectDot({super.key, required this.selected, this.size = 26});
  final bool selected;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: selected ? SL.accent : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? SL.accent : const Color(0x668CDCFF), width: 2),
        ),
        child: selected ? Icon(Icons.check_rounded, size: size * 0.7, color: SL.onAccent) : null,
      );
}

/// One conversation in the Alerts tab: avatar, sender, newest message and time, how many, the worst verdict and NEW.
/// In selection mode a check replaces the avatar.
class AlertGroupCard extends StatelessWidget {
  const AlertGroupCard({
    super.key,
    required this.group,
    required this.onTap,
    this.onLongPress,
    this.selecting = false,
    this.selected = false,
  });
  final AlertGroup group;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selecting, selected;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final level = g.level;
    final bad = level != 'safe';
    final fg = SL.fgOf(level);
    final Color fill, edge;
    if (selected) {
      fill = SL.accent.withAlpha(22);
      edge = SL.accent;
    } else if (level == 'danger') {
      fill = fg.withAlpha(18);
      edge = fg.withAlpha(102);
    } else if (level == 'warning') {
      fill = fg.withAlpha(15);
      edge = fg.withAlpha(89);
    } else {
      fill = SL.glass;
      edge = SL.glassBorder;
    }
    final who = g.sender.isEmpty ? tr('Unknown sender') : g.sender;
    final m = g.mark;
    final mAction = '${m?['action'] ?? ''}';
    final r = BorderRadius.circular(20);
    return Semantics(
      selected: selecting ? selected : null,
      button: true,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: edge, width: selected ? 1.5 : 1)),
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: selecting ? SelectDot(selected: selected) : SenderAvatar(level: level, sms: g.hasSms, call: g.hasCall),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Row(children: [
                        Flexible(
                          child: Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: SL.text)),
                        ),
                        if (g.isNew) ...[const SizedBox(width: 8), AlertTag(tr('NEW'), color: SL.accentLight, bg: SL.accent.withAlpha(36))],
                        if (g.isTest) ...[const SizedBox(width: 6), AlertTag(tr('Test'), color: SL.textSecondary, bg: const Color(0x14FFFFFF))],
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Text(alertWhen(context, g.at), style: const TextStyle(fontSize: 12, color: SL.textMuted)),
                  ]),
                  const SizedBox(height: 3),
                  Text(g.previewLine, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: SL.textSoft, height: 1.35)),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (bad || g.count > 1) alertLevelPill(context, level),
                    _CountChip(alertCountLabel(g.smsCount, g.callCount), highlight: g.count > 1),
                    if (m != null) AlertBadge(markLabel(mAction), icon: markIcon(mAction), color: mAction == 'comment' ? SL.accent : SL.fgOf(markLevel(mAction))),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "5 messages" — a quiet count chip, brighter when there is more than one.
class _CountChip extends StatelessWidget {
  const _CountChip(this.text, {this.highlight = false});
  final String text;
  final bool highlight;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: highlight ? SL.accent.withAlpha(26) : const Color(0x0DFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: highlight ? SL.accent.withAlpha(90) : const Color(0x268CDCFF)),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: highlight ? SL.accentLight : SL.textSecondary)),
      );
}

/// A 44 px action button: red filled (Block), quiet outlined, green-tinted (WhatsApp) or highlighted when chosen.
class AlertActionButton extends StatelessWidget {
  const AlertActionButton({super.key, required this.label, required this.onTap, this.filled = false, this.tint, this.selected = false, this.selColor, this.icon});
  final String label;
  final VoidCallback? onTap;
  final bool filled, selected;
  final Color? tint, selColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(12);
    final Color fill, edge, text;
    if (filled) {
      fill = SL.dangerD;
      edge = SL.dangerD;
      text = SL.onDanger;
    } else if (tint != null) {
      fill = tint!.withAlpha(26);
      edge = tint!.withAlpha(115);
      text = SL.pale('safe');
    } else if (selected && selColor != null) {
      fill = selColor!.withAlpha(36);
      edge = selColor!;
      text = SL.text;
    } else {
      fill = const Color(0x0AFFFFFF);
      edge = const Color(0x2EFFFFFF);
      text = SL.text;
    }
    return Material(
      color: fill,
      shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: edge)),
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, size: 17, color: text), const SizedBox(width: 6)],
              Text(label, maxLines: 1, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: text)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The 44 px "⋯" button next to the action buttons.
class AlertMoreButton extends StatelessWidget {
  const AlertMoreButton({super.key, required this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(12);
    return Tooltip(
      message: tr('More'),
      child: Material(
        color: const Color(0x0AFFFFFF),
        shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: Color(0x2EFFFFFF))),
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: const SizedBox(width: 44, height: 44, child: Icon(Icons.more_horiz_rounded, size: 20, color: SL.text)),
        ),
      ),
    );
  }
}
