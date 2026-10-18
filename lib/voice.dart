import 'package:flutter/material.dart';

import 'i18n/i18n.dart';
import 'i18n/reasons.dart';
import 'native.dart';

/// Reads a result aloud in the chosen language, using the phone's (or browser's) own text-to-speech.
/// Nothing is sent anywhere.
class Voice {
  Voice._();

  /// Read results aloud automatically when they appear. OFF unless the user switched it on in Settings.
  static bool auto = false;

  /// Voice id chosen in Settings ('' = the phone's default voice). Ids come from [voices].
  static String voiceName = '';

  static const normalRate = 0.92;
  static const slowRate = 0.75;

  /// Speaking speed (1.0 = the engine's normal speed).
  static double rate = normalRate;
  static bool get slow => rate < normalRate;

  static void init(Map<String, dynamic>? status) {
    final prefs = status?['prefs'] as Map?;
    // Off by default: a missing or empty pref means off.
    auto = '${prefs?['voice'] ?? ''}' == 'on';
    voiceName = '${prefs?['voice_name'] ?? ''}';
    rate = '${prefs?['voice_rate'] ?? ''}' == 'slow' ? slowRate : normalRate;
  }

  static Future<void> setAuto(bool on) async {
    auto = on;
    await Native.instance.trySetPref('voice', on ? 'on' : 'off');
  }

  static Future<void> setVoiceName(String id) async {
    voiceName = id;
    await Native.instance.trySetPref('voice_name', id);
  }

  static Future<void> setSlow(bool on) async {
    rate = on ? slowRate : normalRate;
    await Native.instance.trySetPref('voice_rate', on ? 'slow' : 'normal');
  }

  static final _voices = <String, List<Map<String, dynamic>>>{};

  /// Voices installed for [lang] (best first), cached for this session.
  static Future<List<Map<String, dynamic>>> voices(String lang, {bool reload = false}) async {
    if (!reload && _voices.containsKey(lang)) return _voices[lang]!;
    final v = await Native.instance.listVoices(lang);
    _voices[lang] = v;
    return v;
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

  /// Speaks [text] in the current language. [voice] overrides the saved voice (used for previews in Settings).
  static Future<bool> speak(String text, {String? voice}) async {
    final lang = L10n.lang.value;
    try {
      var v = voice;
      if (v == null && voiceName.isNotEmpty) {
        // The saved voice may belong to another language: only use it when it's one of this language's voices.
        final list = await voices(lang);
        if (list.any((e) => '${e['id']}' == voiceName)) v = voiceName;
      }
      return await Native.instance.speak(text, lang, voice: v, rate: rate);
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

/// "Listen" button for a result. Reads it out automatically only if the user switched that on in Settings (off by default).
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
