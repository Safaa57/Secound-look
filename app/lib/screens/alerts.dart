import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../native.dart';
import '../widgets/common.dart';
import 'home.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<Map<String, dynamic>> items = [];
  String filter = 'all';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final h = await Native.instance.history();
    if (mounted) setState(() => items = h);
  }

  @override
  Widget build(BuildContext context) {
    final shown = items.where((a) => filter == 'all' || a['kind'] == filter).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Alerts')), actions: [
        const LanguageButton(),
        IconButton(tooltip: tr('Refresh'), onPressed: load, icon: const Icon(Icons.refresh_rounded)),
        if (items.isNotEmpty)
          IconButton(
            tooltip: tr('Clear all'),
            onPressed: () async {
              await Native.instance.clearHistory();
              load();
            },
            icon: const Icon(Icons.delete_sweep_rounded),
          ),
      ]),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'all', label: Text(tr('All'))),
              const ButtonSegment(value: 'sms', label: Text('SMS'), icon: Icon(Icons.sms_rounded)),
              ButtonSegment(value: 'call', label: Text(tr('Calls')), icon: const Icon(Icons.call_rounded)),
            ],
            selected: {filter},
            onSelectionChanged: (s) => setState(() => filter = s.first),
          ),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            Panel(child: Text(tr('No alerts yet. Alerts are kept only on this phone, and you can clear them any time.')))
          else
            for (final a in shown) ...[AlertTile(a: a), const SizedBox(height: 10)],
        ]),
      ),
    );
  }
}
