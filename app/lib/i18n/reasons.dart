import 'dart:convert';

import 'package:flutter/services.dart';

/// Hindi and Kannada texts for what the scam engine says (reasons, advice, caller types, report types),
/// loaded from assets/i18n/i18n.json. The same file is used by Android notifications.
class I18nData {
  I18nData._();
  static Map<String, dynamic> _d = const {};

  static Future<void> load() async {
    try {
      _d = (jsonDecode(await rootBundle.loadString('assets/i18n/i18n.json')) as Map).cast<String, dynamic>();
    } catch (_) {
      _d = const {}; // English still works
    }
  }

  static String? lookup(String section, String lang, String key) {
    if (lang == 'en') return null;
    final m = (_d[section] as Map?)?[lang];
    final v = m is Map ? m[key] : null;
    return v is String ? v : null;
  }

  static List? pair(String section, String lang, String key) {
    if (lang == 'en') return null;
    final m = (_d[section] as Map?)?[lang];
    final v = m is Map ? m[key] : null;
    return v is List && v.length >= 2 ? v : null;
  }
}

class ReasonText {
  const ReasonText(this.title, this.detail);
  final String title, detail;
}

ReasonText? reasonText(String lang, String id) {
  var p = I18nData.pair('reasons', lang, id);
  if (p == null && id.startsWith('sender_')) p = I18nData.pair('reasons', lang, id.substring(7));
  return p == null ? null : ReasonText('${p[0]}', '${p[1]}');
}

String? adviceText(String lang, String en) => I18nData.lookup('advice', lang, en);
String? callerLabel(String lang, String kind) => I18nData.lookup('callers', lang, kind);
String? reportTypeLabel(String lang, String id) => I18nData.lookup('reportTypes', lang, id);
String? numberTypeLabel(String lang, String en) => I18nData.lookup('numberTypes', lang, en);
String? voicePhrase(String lang, String key) => I18nData.lookup('voice', lang, key);
