import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../monetize/monetize.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The Offers tab: a few sponsored cards and an optional "support us" ad. Second Look is free because of these ads,
/// and says so plainly. Nothing here loads until the tab is opened.
class OffersScreen extends StatefulWidget {
  const OffersScreen({super.key});
  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  static const _cards = 3;

  /// Bumped by "Try again": new cards, new ad requests.
  int _round = 0;
  int _loaded = 0, _failed = 0;
  bool _waitedTooLong = false;
  bool _supporting = false;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    Monetize.ready.addListener(_onReady);
    _startWait();
  }

  @override
  void dispose() {
    Monetize.ready.removeListener(_onReady);
    _wait?.cancel();
    super.dispose();
  }

  void _onReady() {
    if (mounted) setState(() {});
  }

  /// If ads can't start (offline, or no ad consent), show the calm empty state instead of a spinner forever.
  void _startWait() {
    _wait?.cancel();
    _waitedTooLong = false;
    _wait = Timer(const Duration(seconds: 12), () {
      if (mounted) setState(() => _waitedTooLong = true);
    });
  }

  void _result(int round, bool ok) {
    if (!mounted || round != _round) return;
    setState(() {
      if (ok) {
        _loaded++;
      } else {
        _failed++;
      }
    });
  }

  void _retry() {
    setState(() {
      _round++;
      _loaded = 0;
      _failed = 0;
    });
    _startWait();
    Monetize.init();
  }

  Future<void> _support() async {
    if (_supporting) return;
    setState(() => _supporting = true);
    final watched = await Monetize.showSupportAd();
    if (!mounted) return;
    setState(() => _supporting = false);
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(watched ? tr('Thank you for supporting Second Look!') : tr('No ad is available right now. Thank you for wanting to help!')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final ready = Monetize.ready.value;
    final empty = _loaded == 0 && (_failed >= _cards || (!ready && _waitedTooLong));
    final looking = _loaded == 0 && !empty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 24), children: [
          Text(tr('Offers'), maxLines: 1, overflow: TextOverflow.ellipsis, style: SL.h(28)),
          const SizedBox(height: 8),
          Text(
            tr('Second Look is free because of these ads. Ads never see your messages, calls or documents.'),
            style: const TextStyle(fontSize: 14.5, height: 1.45, color: SL.textSecondary),
          ),
          const SizedBox(height: 18),
          if (ready)
            for (var i = 0; i < _cards; i++)
              NativeAdCard(
                key: ValueKey('offer-$_round-$i'),
                medium: true,
                margin: const EdgeInsets.only(bottom: 14),
                onResult: (ok) => _result(_round, ok),
              ),
          if (looking)
            const Panel(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 22),
              child: Row(children: [
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 14),
                Expanded(child: _LookingText()),
              ]),
            ),
          if (empty) _Empty(onRetry: _retry),
          const SizedBox(height: 10),
          SoftButton(
            label: _supporting ? tr('Loading the ad…') : tr('Support Second Look — watch a short ad'),
            icon: Icons.volunteer_activism_outlined,
            onPressed: _supporting ? null : _support,
          ),
          const SizedBox(height: 10),
          Text(
            tr('Optional. Nothing is unlocked; it simply helps keep Second Look free. Change your ad choices in Me › Your privacy.'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, height: 1.4, color: SL.textMuted),
          ),
        ]),
      ),
    );
  }
}

class _LookingText extends StatelessWidget {
  const _LookingText();
  @override
  Widget build(BuildContext context) => Text(tr('Looking for offers…'), style: const TextStyle(fontWeight: FontWeight.w600, color: SL.textSoft));
}

/// No offers: offline, nothing to show, or no ad consent. Calm, and clear that protection is unaffected.
class _Empty extends StatelessWidget {
  const _Empty({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const IconTile(Icons.local_offer_outlined, color: SL.accent),
          const SizedBox(height: 14),
          Text(tr('No offers right now'), style: SL.h(19)),
          const SizedBox(height: 6),
          Text(
            tr('Offers couldn\'t load, maybe because you\'re offline. Second Look keeps protecting you either way, for free.'),
            style: const TextStyle(fontSize: 14, height: 1.45, color: SL.textSoft),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: Text(tr('Try again'))),
        ]),
      );
}
