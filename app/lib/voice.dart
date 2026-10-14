import 'package:flutter/material.dart';

import 'i18n/i18n.dart';
import 'i18n/reasons.dart';
import 'native.dart';

/// Reads a result aloud in the chosen language, using the phone's (or browser's) own text-to-speech.
/// Nothing is sent anywhere.
class Voice {
  Voice._();

  /// Read results aloud automatically when they appear. Switched in Settings.
  static bool auto = true;

  static void init(Map<String, dynamic>? status) {
    auto = '${(status?['prefs'] as Map?)?['voice'] ?? ''}' != 'off';
  }

  static Future<void> setAuto(bool on) async {
    auto = on;
    try {
      await Native.instance.setPref('voice', on ? 'on' : 'off');
    } catch (_) {}
  }

  static const _en = {
    'danger': 'Warning. This looks like a scam.',
    'warning': 'Be careful. This looks suspicious.',
    'safe': 'No strong warning signs found.',
    'payment_safe': 'No red flags found. Confirm the money in your own bank app before you hand anything over.',
  };

  /// The sentence spoken for a result: the verdict, the main reason and the first thing to do.
  static String sentence(Map<String, dynamic> r) {
    final lang = L10n.lang.value;
    final key = '${(r['level'] as Map?)?['key'] ?? 'safe'}';
    final vk = r['kind'] == 'payment' && key == 'safe' ? 'payment_safe' : key;
    final parts = <String>[voicePhrase(lang, vk) ?? _en[vk] ?? _en['safe']!];
    final reasons = ((r['reasons'] as List?) ?? []).cast<Map>().where((x) => ((x['weight'] as num?) ?? 0) > 0).toList();
    if (reasons.isNotEmpty && key != 'safe') parts.add(trReasonTitle(reasons.first));
    final advice = ((r['advice'] as List?) ?? []).cast<String>();
    if (advice.isNotEmpty) parts.add(trAdvice(advice.first));
    return parts.map((s) => s.trim().endsWith('.') || s.trim().endsWith('।') ? s.trim() : '${s.trim()}.').join(' ');
  }

  static Future<bool> speak(String text) async {
    try {
      return await Native.instance.speak(text, L10n.lang.value);
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await Native.instance.stopSpeaking();
    } catch (_) {}
  }
}

/// "Listen" button for a result; also reads it out once automatically if that's switched on.
class ListenButton extends StatefulWidget {
  const ListenButton({super.key, required this.result, this.autoPlay = true, this.color});
  final Map<String, dynamic> result;
  final bool autoPlay;
  final Color? color;
  @override
  State<ListenButton> createState() => _ListenButtonState();
}

class _ListenButtonState extends State<ListenButton> {
  bool speaking = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPlay && Voice.auto) WidgetsBinding.instance.addPostFrameCallback((_) => _play(silentFail: true));
  }

  @override
  void dispose() {
    if (speaking) Voice.stop();
    super.dispose();
  }

  Future<void> _play({bool silentFail = false}) async {
    if (speaking) {
      await Voice.stop();
      if (mounted) setState(() => speaking = false);
      return;
    }
    setState(() => speaking = true);
    final ok = await Voice.speak(Voice.sentence(widget.result));
    if (!mounted) return;
    if (!ok) {
      setState(() => speaking = false);
      if (!silentFail) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('The voice for {lang} isn\'t installed on this device. Add it in your phone\'s text-to-speech settings.',
              {'lang': L10n.names[L10n.lang.value]})),
        ));
      }
      return;
    }
    // Speech has no reliable "finished" signal on every platform; reset the button after a while.
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted) setState(() => speaking = false);
    });
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: widget.color, minimumSize: const Size(0, 44)),
        onPressed: _play,
        icon: Icon(speaking ? Icons.stop_circle_rounded : Icons.volume_up_rounded),
        label: Text(speaking ? tr('Stop') : tr('Listen')),
      );
}
