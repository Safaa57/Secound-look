import 'cloud.dart';
import 'native.dart';

/// Shared community reports: how many Second Look users reported a number, why, and their notes.
///
/// - Checking a number sends only that number to our server, to look up reports. Lookups aren't stored.
/// - Call Shield doesn't send anything: it matches incoming calls against a downloaded list on the phone.
class Community {
  Community._();

  static bool enabled(Map<String, dynamic>? status) =>
      Cloud.configured && ((status?['prefs'] as Map?)?['community_off'] ?? '') != '1';

  /// Adds community reports to a number result: score, verdict and a summary for the Community card.
  static Future<Map<String, dynamic>> enrich(Map<String, dynamic> result, Map<String, dynamic>? status) async {
    if (!enabled(status)) return result;
    final info = (result['info'] as Map?)?.cast<String, dynamic>() ?? {};
    final d = (info['numberDetails'] as Map?)?.cast<String, dynamic>();
    final e164 = d?['e164'] as String?;
    if (result['kind'] != 'number' || e164 == null) return result;
    try {
      final c = await Cloud.instance.communityLookup(e164);
      return merge(result, c);
    } catch (_) {
      return result; // offline: the on-device result still stands
    }
  }

  static Map<String, dynamic> merge(Map<String, dynamic> result, Map<String, dynamic> c) {
    final out = Map<String, dynamic>.from(result);
    final reasons = ((result['reasons'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).where((r) => !'${r['id']}'.startsWith('community_')).toList()
      ..addAll(((c['reasons'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()));
    reasons.sort((a, b) => ((b['weight'] as num?) ?? 0).compareTo((a['weight'] as num?) ?? 0));
    var score = reasons.fold<num>(0, (s, r) => s + ((r['weight'] as num?) ?? 0));
    if (reasons.where((r) => ((r['weight'] as num?) ?? 0) >= 25).length >= 2) score += 10;
    if (reasons.any((r) => r['id'] == 'community_scam_many')) score = score < 60 ? 60 : score;
    final sc = score.clamp(0, 100).round();
    out['reasons'] = reasons;
    out['score'] = sc;
    out['level'] = sc >= 50
        ? {'key': 'danger', 'label': 'Likely scam'}
        : sc >= 20
            ? {'key': 'warning', 'label': 'Suspicious'}
            : {'key': 'safe', 'label': 'No strong warning signs'};
    final info = Map<String, dynamic>.from((result['info'] as Map?)?.cast<String, dynamic>() ?? {});
    info['community'] = c;
    if (((c['scam'] as num?) ?? 0) >= 3 && info['caller'] is Map) {
      info['caller'] = {'kind': 'scam', 'label': 'Reported scam number'};
    }
    out['info'] = info;
    final advice = List<String>.from((result['advice'] as List?)?.cast<String>() ?? const []);
    if (((c['scam'] as num?) ?? 0) >= 3 && c['shown'] == true) {
      const a = 'Many people reported this number. Don\'t answer, call back or share anything with it.';
      if (!advice.contains(a)) advice.insert(0, a);
      advice.removeWhere((x) => x.startsWith('No strong warning signs'));
    }
    out['advice'] = advice;
    return out;
  }

  /// Downloads the community scam list for Call Shield, at most every 12 hours.
  static Future<void> syncIfDue(Map<String, dynamic>? status) async {
    if (!enabled(status) || Native.instance.isWeb) return;
    final last = int.tryParse('${(status?['prefs'] as Map?)?['community_sync'] ?? ''}') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < 12 * 3600 * 1000) return;
    try {
      final json = await Cloud.instance.communityList();
      if (await Native.instance.setCommunityList(json)) await Native.instance.setPref('community_sync', '$now');
    } catch (_) {
      // try again next time the app opens
    }
  }
}
