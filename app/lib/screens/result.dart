import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
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
        if (body.isNotEmpty && widget.result['kind'] != 'number')
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurface.withAlpha(14), borderRadius: BorderRadius.circular(16)),
            child: Text(body, style: const TextStyle(fontSize: 15, height: 1.45)),
          ),
        VerdictView(result: widget.result, trustedName: status['trustedName'] as String?, trustedNumber: status['trustedNumber'] as String?),
      ]),
    );
  }
}
