import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../monetize/monetize.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/verdict.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.result, required this.title, this.manual = false});
  final Map<String, dynamic> result;
  final String title;

  /// A check the user started (Check anything, paste, share). Only these can be followed by an ad, and only
  /// after the user leaves the result (see AdRules). Alerts and shields are never manual.
  final bool manual;
  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  Map<String, dynamic> status = {};
  AdTicket? _ad;

  @override
  void initState() {
    super.initState();
    if (widget.manual) _ad = AdRules.manualCheck(widget.result);
    Native.instance.status().then((s) => mounted ? setState(() => status = s) : null);
  }

  /// The result is shown first; any ad comes only once the user has left it (back or done).
  @override
  void dispose() {
    AdRules.leaving(_ad);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = widget.result['input'];
    final body = input is Map ? '${input['body'] ?? ''}' : '${input ?? ''}';
    return Scaffold(
      body: ListView(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 32), children: [
        VerdictView(
          result: widget.result,
          trustedName: status['trustedName'] as String?,
          trustedNumber: status['trustedNumber'] as String?,
          title: widget.title,
          onBack: () => Navigator.of(context).maybePop(),
        ),
        if (body.isNotEmpty && widget.result['kind'] != 'number')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionLabel(tr('What was checked')),
              Panel(padding: const EdgeInsets.all(14), child: _CheckedText(body)),
            ]),
          ),
      ]),
    );
  }
}

/// The checked text: three lines, tap "Show all" for the rest.
class _CheckedText extends StatefulWidget {
  const _CheckedText(this.text);
  final String text;
  @override
  State<_CheckedText> createState() => _CheckedTextState();
}

class _CheckedTextState extends State<_CheckedText> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 15, height: 1.45);
    if (widget.text.length <= 160) return SelectableText(widget.text, style: style);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (open) SelectableText(widget.text, style: style) else Text(widget.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: style),
      TextButton(
        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), foregroundColor: SL.accent),
        onPressed: () => setState(() => open = !open),
        child: Text(open ? tr('Show less') : tr('Show all')),
      ),
    ]);
  }
}
