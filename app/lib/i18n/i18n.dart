import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../native.dart';
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
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withAlpha(26),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.translate_rounded, size: 17, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text(L10n.names[code]!, style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
            ]),
          ),
        ),
      );
}
