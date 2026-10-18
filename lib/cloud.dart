import 'dart:convert';

import 'package:http/http.dart' as http;

import 'i18n/i18n.dart';
import 'native.dart';

/// Talks to the Second Look cloud service (online deep checks, quota, Plus).
/// Sends only links and a random install id: never message text, senders or phone numbers.
class Cloud {
  Cloud._();
  static final Cloud instance = Cloud._();

  /// Set at build time: flutter build ... --dart-define=SL_API=https://your-server.example.com
  static const String baseUrl = String.fromEnvironment('SL_API');
  static bool get configured => baseUrl.startsWith('https://');

  static String get _base => baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  String? _iid;

  /// Forget the cached id (after "Delete all my data" creates a new one).
  void reset() => _iid = null;
  Future<String> installId() async => _iid ??= await Native.instance.installId();

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await http
        .post(Uri.parse('$_base$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    Object? data;
    try {
      data = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    } on FormatException {
      data = null; // e.g. an HTML error page from a proxy
    }
    if (res.statusCode >= 400) throw CloudError(res.statusCode, data is Map ? data['detail'] : null);
    if (data is! Map) throw CloudError(res.statusCode, null);
    return data.cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> quota() async => _post('/v1/quota', {'install_id': await installId()});

  Future<Map<String, dynamic>> deepCheck(List<String> urls) async =>
      _post('/v1/deep-check', {'install_id': await installId(), 'urls': urls.take(5).toList()});

  Future<Map<String, dynamic>> verifyPlus({required String platform, required String productId, required String token}) async =>
      _post('/v1/plus/verify', {'install_id': await installId(), 'platform': platform, 'product_id': productId, 'token': token});

  Future<String> linkCode() async => (await _post('/v1/plus/link-code', {'install_id': await installId()}))['code'] as String;

  // ---- community reports ----
  Future<Map<String, dynamic>> communityLookup(String number) async =>
      _post('/v1/community/lookup', {'install_id': await installId(), 'number': number});

  Future<Map<String, dynamic>> communityReport(String number, String type, {String claimed = '', String note = ''}) async =>
      _post('/v1/community/report', {'install_id': await installId(), 'number': number, 'type': type, 'claimed': claimed, 'note': note});

  Future<void> communityFlag(String number, String commentId) async {
    await _post('/v1/community/flag', {'install_id': await installId(), 'number': number, 'comment_id': commentId});
  }

  Future<Map<String, dynamic>> communityDispute(String number, String reason) async =>
      _post('/v1/community/dispute', {'install_id': await installId(), 'number': number, 'reason': reason});

  /// The public list of numbers many users reported. Returns the raw JSON text.
  Future<String> communityList() async {
    final res = await http.get(Uri.parse('$_base/v1/community/list')).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw CloudError(res.statusCode, null);
    return res.body;
  }

  /// Everything our server keeps for this install (right to access).
  Future<Map<String, dynamic>> myData() async => _post('/v1/my-data', {'install_id': await installId()});

  /// Deletes everything our server keeps for this install (right to erasure).
  Future<void> forget() async {
    await _post('/v1/forget', {'install_id': await installId()});
  }

  Future<Map<String, dynamic>> claimLink(String code) async => _post('/v1/plus/link', {'install_id': await installId(), 'code': code});

  /// Links found by the on-device check, for an optional online deep check.
  static List<String> linksIn(Map<String, dynamic> result) {
    final info = (result['info'] as Map?) ?? {};
    if (result['kind'] == 'link' && info['url'] != null) return [info['url'] as String];
    final links = (info['links'] as List?) ?? [];
    return links.map((l) => ((l as Map)['info'] as Map?)?['url'] as String? ?? '').where((u) => u.isNotEmpty).toList();
  }
}

class CloudError implements Exception {
  CloudError(this.status, this.detail);
  final int status;
  final dynamic detail;

  bool get needsAdOrPlus => status == 402 && detail is Map && detail['need'] == 'ad_or_plus';

  String get message {
    if (detail is String) return detail as String;
    if (detail is Map && detail['message'] != null) return detail['message'] as String;
    if (status == 429) return tr('Too many checks right now. Wait a minute.');
    return tr('The online check isn\'t available right now.');
  }

  @override
  String toString() => message;
}
