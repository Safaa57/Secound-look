import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../checks/aadhaar_qr.dart';
import '../checks/picker.dart';
import '../community.dart';
import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'document_check.dart';
import 'payment_check.dart';
import 'result.dart';
import 'upi_check.dart';

/// "Check anything": point the camera at a QR, screenshot or letter, or paste a link, SMS, number or UPI ID.
/// The app works out what it is and opens the right check. Everything is checked on the device.
class CheckScreen extends StatefulWidget {
  const CheckScreen({super.key, this.onBack});

  /// Back button action when this is a tab (goes to Home). When pushed as a page, back pops it.
  final VoidCallback? onBack;

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> with SingleTickerProviderStateMixin {
  final text = TextEditingController();
  final sender = TextEditingController();
  Map<String, dynamic> status = {};
  bool running = false;
  bool scanning = false;

  /// The scan line in the camera panel (3 s up and down).
  late final AnimationController scan = AnimationController(vsync: this, duration: const Duration(seconds: 3));

  static const examples = [
    ['Bank KYC SMS', '+919812345678', 'Dear customer, your SBI account will be blocked today. Update PAN now: http://sbi-yono-kyc.top/update'],
    ['Unknown number', '', '+92 300 1234567'],
    ['Fake shop link', '', 'https://www.amaz0n-offers.in/gift'],
    ['Real bank alert', 'VM-SBIINB-T', 'Rs.2,500 debited from A/c XX1234 on 10-Oct. Not you? Call 1800 1234.'],
    ['"Sent by mistake"', '+919812345678', 'Sir I sent Rs 5000 to your number by mistake, please return the amount to rahul.refund@ybl'],
    ['Call forwarding trick', '', 'To upgrade your SIM to 5G, dial *401*9876543210 now'],
  ];

  static final _upiId = RegExp(r'^[a-zA-Z0-9._-]{2,64}@[a-zA-Z][a-zA-Z0-9]{1,30}$');

  /// Words that mean a picture is a payment screenshot.
  static final _paymentWords = RegExp(
      r'(upi\s*ref|\butr\b|transaction\s*id|txn\s*id|payment\s+(successful|success|completed|done|pending|failed)|paid\s+to|sent\s+to|received\s+from|money\s+sent|amount\s+paid)',
      caseSensitive: false);

  /// Words that mean a picture is an ID, statement or letter.
  static final _documentWords = RegExp(
      r'(aadhaar|aadhar|uidai|income\s*tax|permanent\s+account|passport|government\s+of\s+india|election\s+commission|driving\s+licen[cs]e|statement\s+of\s+account|account\s+statement|salary\s+slip|pay\s*slip|offer\s+letter|appointment\s+letter|invoice|certificate|notice|court|summons)',
      caseSensitive: false);

  @override
  void initState() {
    super.initState();
    Native.instance.status().then((s) => mounted ? setState(() => status = s) : null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      scan.stop();
      scan.value = 0.5;
    } else if (!scan.isAnimating) {
      scan.repeat();
    }
  }

  @override
  void dispose() {
    scan.dispose();
    text.dispose();
    sender.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _push(Widget page) async {
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _showResult(Map<String, dynamic> r) => _push(ResultScreen(result: r, title: 'Check result'));

  /// The normal check (link / SMS / number / UPI ID, worked out by the engine), plus community reports.
  Future<Map<String, dynamic>> _analyze(String t, {String from = ''}) async {
    final r = from.isNotEmpty ? await Native.instance.analyzeSms(from, t) : await Native.instance.analyze(t);
    status = await Native.instance.status(); // the community setting may have changed in Settings
    return Community.enrich(r, status);
  }

  Future<void> run() async {
    final t = text.text.trim();
    if (t.isEmpty) {
      _snack(tr('Paste a link, message, number or UPI ID first.'));
      return;
    }
    if (running) return;
    FocusScope.of(context).unfocus();
    setState(() => running = true);
    Map<String, dynamic>? r;
    try {
      r = await _analyze(t, from: sender.text.trim());
    } on PlatformException catch (e) {
      _snack(e.message ?? tr('The check failed'));
    } catch (_) {
      _snack(tr('The check failed'));
    }
    if (!mounted) return;
    setState(() => running = false);
    final res = r;
    if (res != null) await _showResult(res);
  }

  Future<void> paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text;
    if (mounted && t != null && t.trim().isNotEmpty) setState(() => text.text = t.length > 10000 ? t.substring(0, 10000) : t);
  }

  /// A photo or screenshot: reads it on the device and opens the right check.
  /// QR → Aadhaar (document check), UPI (UPI check) or a link (normal check); payment screenshot → payment check;
  /// an ID, statement, letter or camera photo → document check; any other screenshot → its words are checked.
  Future<void> _image({required bool camera}) async {
    if (scanning || running) return;
    FocusScope.of(context).unfocus();
    setState(() => scanning = true);
    try {
      final img = await ImageReader.pick(camera: camera, layout: true);
      if (!mounted || img == null) return;
      if (img.bytes.isEmpty) {
        _snack(tr(img.readError ?? 'Couldn\'t open this file.'));
        return;
      }
      if (img.qr.isNotEmpty) {
        final code = img.qr.first.trim();
        if (AadhaarQr.decode(code) != null) {
          await _push(DocumentCheckScreen(initialImage: img));
          return;
        }
        final isUpi = RegExp(r'^upi:', caseSensitive: false).hasMatch(code) || _upiId.hasMatch(code);
        final value = code.length > 2048 ? code.substring(0, 2048) : code;
        final r = isUpi ? await Native.instance.analyzeUpi(value) : await _analyze(value);
        await _showResult(r);
        return;
      }
      final words = img.text.trim();
      if (words.isNotEmpty && _paymentWords.hasMatch(words)) {
        await _push(PaymentCheckScreen(initialImage: img));
        return;
      }
      if (words.isEmpty || camera || _documentWords.hasMatch(words)) {
        await _push(DocumentCheckScreen(initialImage: img));
        return;
      }
      // A screenshot of a message or chat: check its words like pasted text.
      final t = words.length > 10000 ? words.substring(0, 10000) : words;
      setState(() => text.text = t);
      final r = await _analyze(t);
      await _showResult(r);
    } on PlatformException catch (e) {
      _snack(e.message ?? tr('Couldn\'t open the camera or photos.'));
    } catch (_) {
      _snack(tr('The check failed'));
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final web = Native.instance.isWeb || status['platform'] == 'web';
    final bottom = MediaQuery.paddingOf(context).bottom;
    final canBack = widget.onBack != null || (ModalRoute.of(context)?.canPop ?? false);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(padding: EdgeInsets.fromLTRB(20, 16, 20, bottom + 24), children: [
          Row(children: [
            if (canBack) ...[BackCircle(onPressed: widget.onBack), const SizedBox(width: 12)],
            Expanded(child: Text(tr('Check anything'), maxLines: 2, overflow: TextOverflow.ellipsis, style: SL.h(24))),
          ]),
          const SizedBox(height: 18),
          _Scanner(
            anim: scan,
            busy: scanning,
            label: tr('Point at a QR, screenshot or letter'),
            onTap: () => _image(camera: !kIsWeb),
          ),
          const SizedBox(height: 18),
          Text(tr('Or paste it here'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: SL.textSecondary)),
          const SizedBox(height: 8),
          TextField(
            controller: text,
            minLines: 3,
            maxLines: 8,
            inputFormatters: [LengthLimitingTextInputFormatter(10000)],
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: SL.text),
            decoration: InputDecoration(hintText: tr('Link, SMS, phone number or UPI ID')),
          ),
          LearnMore(
            label: tr('Add who sent it (optional)'),
            initiallyOpen: sender.text.isNotEmpty,
            child: TextField(
              controller: sender,
              decoration: InputDecoration(
                labelText: tr('Who sent it? (optional)'),
                hintText: tr('e.g. VM-SBIINB-T or +91 98xxx xxx10'),
                prefixIcon: const Icon(Icons.person_search_rounded),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _Square(icon: Icons.content_paste_rounded, label: tr('Paste'), onTap: paste)),
            const SizedBox(width: 10),
            Expanded(child: _Square(icon: Icons.photo_library_outlined, label: tr('Gallery'), onTap: scanning ? null : () => _image(camera: false))),
            const SizedBox(width: 10),
            Expanded(child: _Square(icon: Icons.insert_drive_file_outlined, label: tr('File'), onTap: () => _push(const DocumentCheckScreen(pickFileOnOpen: true)))),
          ]),
          const SizedBox(height: 18),
          GlowButton(label: running ? tr('Checking…') : tr('Check now'), busy: running, height: 62, onPressed: run),
          const SizedBox(height: 12),
          Text(
            web ? tr('We figure out what it is. Checked in this browser, never uploaded.') : tr('We figure out what it is. Checked on your phone, never uploaded.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: SL.textMuted, fontSize: 13),
          ),
          SectionLabel(tr('More checks')),
          Row(children: [
            Expanded(child: _Square(icon: Icons.receipt_long_outlined, label: tr('Payment proof'), onTap: () => _push(const PaymentCheckScreen()))),
            const SizedBox(width: 10),
            Expanded(child: _Square(icon: Icons.qr_code_2_rounded, label: tr('UPI or QR'), onTap: () => _push(const UpiCheckScreen()))),
            const SizedBox(width: 10),
            Expanded(child: _Square(icon: Icons.badge_outlined, label: tr('Document'), onTap: () => _push(const DocumentCheckScreen()))),
          ]),
          SectionLabel(tr('Try an example')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in examples)
              ActionChip(
                label: Text(tr(e[0])),
                onPressed: () {
                  sender.text = e[1];
                  text.text = e[2];
                  run();
                },
              ),
          ]),
        ]),
      ),
    );
  }
}

/// The 230 px camera panel: cyan corner brackets and a glowing scan line that sweeps up and down.
class _Scanner extends StatelessWidget {
  const _Scanner({required this.anim, required this.busy, required this.label, required this.onTap});
  final Animation<double> anim;
  final bool busy;
  final String label;
  final VoidCallback onTap;

  static const _h = 230.0;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(24);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: SL.accent.withAlpha(13),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: SL.accent.withAlpha(89))),
        child: InkWell(
          onTap: busy ? null : onTap,
          child: SizedBox(
            height: _h,
            child: Stack(children: [
              const Positioned(left: 16, top: 16, child: _Corner(flipX: false, flipY: false)),
              const Positioned(right: 16, top: 16, child: _Corner(flipX: true, flipY: false)),
              const Positioned(left: 16, bottom: 16, child: _Corner(flipX: false, flipY: true)),
              const Positioned(right: 16, bottom: 16, child: _Corner(flipX: true, flipY: true)),
              AnimatedBuilder(
                animation: anim,
                builder: (context, child) {
                  // 12% → 82% → 12% of the height, easing at both ends.
                  final v = anim.value;
                  final phase = v < 0.5 ? v * 2 : (1 - v) * 2;
                  final e = Curves.easeInOut.transform(phase.clamp(0.0, 1.0).toDouble());
                  return Positioned(left: 30, right: 30, top: _h * (0.12 + 0.70 * e), child: child!);
                },
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: SL.accent,
                    boxShadow: [BoxShadow(color: SL.accent.withAlpha(140), blurRadius: 18, spreadRadius: 4)],
                  ),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (busy)
                      const SizedBox(width: 44, height: 44, child: Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 3)))
                    else
                      const Icon(Icons.photo_camera_outlined, size: 44, color: SL.accent),
                    const SizedBox(height: 10),
                    Text(label, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: SL.text)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One 28 px corner bracket (3 px, rounded 8 px), mirrored for the other corners.
class _Corner extends StatelessWidget {
  const _Corner({required this.flipX, required this.flipY});
  final bool flipX, flipY;
  @override
  Widget build(BuildContext context) => SizedBox(width: 28, height: 28, child: CustomPaint(painter: _CornerPainter(flipX, flipY)));
}

class _CornerPainter extends CustomPainter {
  _CornerPainter(this.flipX, this.flipY);
  final bool flipX, flipY;

  @override
  void paint(Canvas canvas, Size s) {
    canvas.save();
    if (flipX) {
      canvas.translate(s.width, 0);
      canvas.scale(-1, 1);
    }
    if (flipY) {
      canvas.translate(0, s.height);
      canvas.scale(1, -1);
    }
    const w = 3.0, h = w / 2, r = 8.0;
    final path = Path()
      ..moveTo(h, s.height)
      ..lineTo(h, r + h)
      ..arcToPoint(const Offset(r + h, h), radius: const Radius.circular(r))
      ..lineTo(s.width, h);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..color = SL.accent,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CornerPainter o) => o.flipX != flipX || o.flipY != flipY;
}

/// A 76 px square button with an icon over a one-word label (Paste / Gallery / File).
class _Square extends StatelessWidget {
  const _Square({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(18);
    return Material(
      color: SL.glass,
      shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: Color(0x298CDCFF))),
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        child: SizedBox(
          height: 76,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 24, color: SL.accent),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: SL.text)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
