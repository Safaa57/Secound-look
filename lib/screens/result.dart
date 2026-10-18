import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/verdict.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.result, required this.title});
  final Map<String, dynamic> result;
  final String title;
  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  Map<String, dynamic> status = {};

  @override
  void initState() {
    super.initState();
    Native.instance.status().then((s) => mounted ? setState(() => status = s) : null);
  }

  @override
  Widget build(BuildContext context) {
    final input = widget.result['input'];
    final body = input is Map ? '${input['body'] ?? ''}' : '${input ?? ''}';
    return Scaffold(
      appBar: AppBar(title: Text(tr(widget.title))),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        VerdictView(result: widget.result, trustedName: status['trustedName'] as String?, trustedNumber: status['trustedNumber'] as String?),
        if (body.isNotEmpty && widget.result['kind'] != 'number') ...[
          SectionLabel(tr('What was checked'), icon: Icons.notes_rounded),
          Panel(
            padding: const EdgeInsets.all(14),
            child: _CheckedText(body),
          ),
        ],
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
