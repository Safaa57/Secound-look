import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../native.dart';
import '../theme.dart';
import 'reasons.dart';
import 'strings_hi.dart';
import 'strings_kn.dart';

/// Languages Second Look speaks. English text is the key; Hindi and Kannada come from the tables.
class L10n {
  L10n._();

  static const supported = ['en', 'hi', 'kn'];
  static const names = {'en': 'English', 'hi': 'हिन्दी', 'kn': 'ಕನ್ನಡ'};
  static const short = {'en': 'EN', 'hi': 'हि', 'kn': 'ಕ'};

  /// The current language. Widgets rebuild when it changes.
  static final lang = ValueNotifier<String>('en');

  static Locale get locale => Locale(lang.value, 'IN');

  /// Picks the saved language, or the phone's language if it's Hindi or Kannada.
  static void init(Map<String, dynamic>? status) {
    final saved = '${(status?['prefs'] as Map?)?['language'] ?? ''}';
    if (supported.contains(saved)) {
      lang.value = saved;
      return;
    }
    final device = ui.PlatformDispatcher.instance.locale.languageCode;
    lang.value = supported.contains(device) ? device : 'en';
  }

  static Future<void> set(String code) async {
    if (!supported.contains(code)) return;
    lang.value = code;
    try {
      await Native.instance.setPref('language', code);
    } catch (e) {
      if (kDebugMode) debugPrint('language not saved: $e');
    }
  }

  static Map<String, String> get _table => lang.value == 'hi' ? stringsHi : lang.value == 'kn' ? stringsKn : const {};
}

/// Translates an English UI string. Use {name} placeholders for values: tr('Risk {n} / 100', {'n': 42}).
String tr(String en, [Map<String, Object?>? args]) {
  var s = L10n._table[en] ?? en;
  if (args != null) {
    args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  }
  return s;
}

/// Translated title for a reason from the engine (falls back to the engine's English text, which may be more specific).
String trReasonTitle(Map r) {
  final t = reasonText(L10n.lang.value, '${r['id']}');
  return t?.title ?? '${r['title'] ?? ''}';
}

String trReasonDetail(Map r) {
  final t = reasonText(L10n.lang.value, '${r['id']}');
  return t?.detail ?? '${r['detail'] ?? ''}';
}

String trAdvice(String en) => adviceText(L10n.lang.value, en) ?? en;

/// Verdict label by level (safe / warning / danger); payment results keep their special wording.
String trLevel(Map level, {String? kind}) {
  final key = '${level['key']}';
  if (kind == 'payment' && key == 'safe') return tr('No red flags found. Confirm in your bank app');
  if (kind == 'document' && key == 'safe') return tr('No signs of forgery found. Confirm with the issuer');
  switch (key) {
    case 'danger':
      return tr('Likely scam');
    case 'warning':
      return tr('Suspicious');
    default:
      return tr('No strong warning signs');
  }
}

/// A compact language switch for the top of each screen.
class LanguageButton extends StatelessWidget {
  const LanguageButton({super.key});

  static const supported = L10n.supported;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: L10n.lang,
        builder: (context, code, _) => PopupMenuButton<String>(
          tooltip: tr('Language'),
          initialValue: code,
          onSelected: L10n.set,
          itemBuilder: (_) => [
            for (final c in L10n.supported)
              PopupMenuItem(value: c, child: Row(children: [
                if (c == code) const Icon(Icons.check_rounded, size: 18) else const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(L10n.names[c]!),
              ])),
          ],
          child: Container(
            height: 44,
            constraints: const BoxConstraints(minWidth: 64),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: SL.accent.withAlpha(20),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: SL.accent.withAlpha(89)),
            ),
            // "EN · हि · ಕ", with the current language brighter.
            child: Text.rich(
              TextSpan(children: [
                for (var i = 0; i < supported.length; i++) ...[
                  if (i > 0) const TextSpan(text: ' · ', style: TextStyle(color: SL.textMuted)),
                  TextSpan(
                    text: L10n.short[supported[i]],
                    style: TextStyle(color: supported[i] == code ? SL.text : SL.textMuted, fontWeight: supported[i] == code ? FontWeight.w800 : FontWeight.w600),
                  ),
                ],
              ]),
              style: const TextStyle(fontFamily: SL.body, fontSize: 14, fontWeight: FontWeight.w700, color: SL.text),
            ),
          ),
        ),
      );
}
