import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' if (dart.library.js_interop) '../web/no_io.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../checks/aadhaar_qr.dart';
import '../checks/image_meta.dart';
import '../checks/pdf_meta.dart';
import '../checks/picker.dart';
import '../i18n/i18n.dart';
import '../native.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/verdict.dart';

/// Checks an ID card, passport, bank statement or letter for common signs of forgery.
/// Everything is read on the device; the file is never uploaded or saved, and results are not kept in history.
class DocumentCheckScreen extends StatefulWidget {
  const DocumentCheckScreen({super.key, this.initialImage, this.pickFileOnOpen = false});

  /// A photo already picked and read on the Check screen.
  final PickedImage? initialImage;

  /// Open the file picker straight away (the File button on the Check screen).
  final bool pickFileOnOpen;

  @override
  State<DocumentCheckScreen> createState() => _DocumentCheckScreenState();
}

class _DocumentCheckScreenState extends State<DocumentCheckScreen> {
  final words = TextEditingController();

  /// The type the user picked with "Wrong type?" (a detected-type key), or null to let the app decide.
  String? chosenType;

  String? fileName;
  String? fileKind; // 'pdf' or 'image'
  Map<String, dynamic>? pdfMeta;
  String? imageEditor;
  Uint8List? preview; // photos only, kept in memory while this screen is open
  Map<String, dynamic>? qr; // Aadhaar QR details, in memory only
  bool qrUnreadable = false;
  Map<String, dynamic>? layout; // text-geometry check from the on-device reader
  Map<String, dynamic>? forensic; // file forensics (photos: ela/screenshot/camera/size; PDFs: fonts/whiteBoxes)

  Map<String, dynamic>? result;
  bool busy = false;
  String Function()? note; // built with tr() when shown, so it follows the language

  @override
  void initState() {
    super.initState();
    final img = widget.initialImage;
    if (img != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final err = img.readError;
        _useImage(
          name: null,
          bytes: img.bytes,
          text: img.text,
          qrs: img.qr,
          editor: img.editor,
          layout: img.layout,
          readNote: err == null ? null : () => tr(err),
        );
      });
    } else if (widget.pickFileOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickFile();
      });
    }
  }

  @override
  void dispose() {
    words.dispose();
    qr = null;
    preview = null;
    Native.instance.clearDocCache();
    super.dispose();
  }

  void _reset() {
    fileName = null;
    fileKind = null;
    pdfMeta = null;
    imageEditor = null;
    preview = null;
    qr = null;
    qrUnreadable = false;
    layout = null;
    forensic = null;
    chosenType = null;
    result = null;
  }

  /// Old check modes the engine still uses when the user overrides the detected type.
  static String _legacyType(String key) {
    switch (key) {
      case 'aadhaar':
      case 'pan':
      case 'voter_id':
      case 'driving_licence':
        return 'id';
      case 'bank_statement':
      case 'salary_slip':
        return 'statement';
      case 'passport':
        return 'passport';
      default:
        return 'letter';
    }
  }

  // File forensics (checks/image_meta.dart and checks/pdf_meta.dart); a failure never stops the check.
  static Future<Map<String, dynamic>?> _imageForensics(Uint8List bytes, String? name) async {
    if (bytes.isEmpty) return null;
    try {
      return await imageForensics(bytes, name: name);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _pdfForensics(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    try {
      return await pdfForensics(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickFile() async {
    setState(() {
      busy = true;
      note = null;
    });
    try {
      final f = await Native.instance.pickDocument();
      if (f == null || !mounted) return;
      await _load(f);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'too_large') {
          note = () => tr('This file is too large. Choose a smaller PDF or photo.');
        } else if (e.code == 'unsupported') {
          note = () => tr('Choose a PDF or a photo (JPG or PNG).');
        } else {
          note = () => tr('Couldn\'t open this file.');
        }
      });
    } catch (_) {
      if (mounted) setState(() => note = () => tr('Couldn\'t open this file.'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _takePhoto() async {
    setState(() {
      busy = true;
      note = null;
    });
    try {
      final img = await ImageReader.pick(camera: true, layout: true);
      if (img == null || !mounted) return;
      final err = img.readError;
      if (img.bytes.isEmpty) {
        setState(() => note = () => tr(err ?? 'Couldn\'t open this file.'));
        return;
      }
      await _useImage(
        name: null,
        bytes: img.bytes,
        text: img.text,
        qrs: img.qr,
        editor: img.editor,
        layout: img.layout,
        readNote: err == null ? null : () => tr(err),
      );
    } on PlatformException {
      if (mounted) setState(() => note = () => tr('Couldn\'t open the camera.'));
    } catch (_) {
      if (mounted) setState(() => note = () => tr('Couldn\'t open this file.'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _load(Map<String, dynamic> f) async {
    final name = '${f['name'] ?? ''}';
    final mime = '${f['mime'] ?? ''}'.toLowerCase();
    final path = f['path'] as String?;
    Uint8List bytes;
    final b64 = f['bytes'];
    if (b64 is String && b64.isNotEmpty) {
      bytes = base64.decode(b64);
    } else if (path != null && !kIsWeb) {
      bytes = await File(path).readAsBytes();
    } else {
      bytes = Uint8List(0);
    }
    final pdf = mime.contains('pdf') || name.toLowerCase().endsWith('.pdf') || _isPdf(bytes);
    final image = !pdf && (mime.startsWith('image/') || RegExp(r'\.(jpe?g|png|webp|heic|heif)$', caseSensitive: false).hasMatch(name));
    if (!mounted) return;
    if (pdf) {
      await _usePdf(name: name, path: path, bytes: bytes);
    } else if (image) {
      var text = '';
      var qrs = <String>[];
      Map<String, dynamic>? lay;
      String Function()? n;
      if (path != null && !kIsWeb) {
        try {
          final r = await Native.instance.readImage(path, layout: true);
          text = (r['text'] as String?) ?? '';
          lay = (r['layout'] as Map?)?.cast<String, dynamic>();
          qrs = ((r['qr'] as List?) ?? const []).map((e) => '$e').toList();
          if (text.trim().isEmpty) n = () => tr('No words could be read in this photo. Type the important lines below.');
        } on PlatformException {
          n = () => tr('Couldn\'t read the words in this photo. Type the important lines below.');
        }
      } else {
        n = () => tr('In the browser the words in a photo can\'t be read. Type the important lines below.');
      }
      await _useImage(name: name, bytes: bytes, text: text, qrs: qrs, editor: ImageMeta.editorIn(bytes), layout: lay, readNote: n);
    } else {
      setState(() => note = () => tr('Choose a PDF or a photo (JPG or PNG).'));
    }
  }

  static bool _isPdf(Uint8List b) => b.length > 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46; // %PDF

  Future<void> _usePdf({required String name, required String? path, required Uint8List bytes}) async {
    final meta = PdfMeta.parse(bytes);
    final fz = await _pdfForensics(bytes);
    var text = '';
    Map<String, dynamic>? lay;
    String Function()? n;
    if (path != null && !kIsWeb) {
      try {
        final r = await Native.instance.readPdf(path);
        text = '${r['text'] ?? ''}';
        lay = (r['layout'] as Map?)?.cast<String, dynamic>();
        final pages = (r['pages'] as num?)?.toInt() ?? 0;
        final read = (r['pagesRead'] as num?)?.toInt() ?? pages;
        if (text.trim().isEmpty) {
          n = () => tr('This PDF has no text to read (it may be a scanned page). Take a photo of the page instead, or type the important lines below.');
        } else if (read < pages) {
          n = () => tr('Only the first {n} of {total} pages were read.', {'n': read, 'total': pages});
        }
      } on PlatformException catch (e) {
        n = e.code == 'locked'
            ? () => tr('This PDF is password-protected, so its text can\'t be read. Type the important lines below.')
            : () => tr('Couldn\'t read the text in this PDF. Type the important lines below.');
      }
    } else {
      n = () => tr('In the browser only the file details are read. Copy the text from the PDF and paste it below.');
    }
    if (!mounted) return;
    setState(() {
      _reset();
      fileName = name.isEmpty ? null : name;
      fileKind = 'pdf';
      pdfMeta = meta;
      layout = lay;
      forensic = fz;
      words.text = text;
      note = n;
    });
    await _check();
  }

  Future<void> _useImage({
    required String? name,
    required Uint8List bytes,
    required String text,
    required List<String> qrs,
    required String? editor,
    Map<String, dynamic>? layout,
    String Function()? readNote,
  }) async {
    final fz = await _imageForensics(bytes, name);
    Map<String, dynamic>? found;
    var unreadable = false;
    for (final q in qrs) {
      final a = await AadhaarQr.read(q);
      if (a == null) continue;
      if (a['decoded'] == true) {
        found = a;
        unreadable = false;
        break;
      }
      unreadable = true;
    }
    if (!mounted) return;
    setState(() {
      _reset();
      fileName = name == null || name.isEmpty ? null : name;
      fileKind = 'image';
      imageEditor = editor;
      this.layout = layout;
      forensic = fz;
      preview = bytes;
      qr = found;
      qrUnreadable = unreadable;
      words.text = text;
      note = readNote;
    });
    await _check();
  }

  Future<void> _check() async {
    if (!mounted) return;
    final t = words.text.trim();
    if (t.isEmpty && fileKind == null) {
      setState(() => note = () => tr('Choose a file, take a photo, or type what the document says.'));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => busy = true);
    try {
      final m = pdfMeta;
      final q = qr;
      final lay = layout;
      final fz = forensic;
      final o = chosenType;
      final input = <String, dynamic>{
        'text': t,
        // The app recognises the type itself; the old check modes are only used when the user corrects it.
        'docType': o == null ? 'auto' : _legacyType(o),
        'file': fileKind == null
            ? <String, dynamic>{}
            : <String, dynamic>{
                'kind': fileKind,
                'producer': m?['producer'],
                'creator': m?['creator'],
                'created': m?['created'],
                'modified': m?['modified'],
                'revisions': m?['revisions'] ?? 0,
                'imageEditor': imageEditor,
                if (lay != null) 'layout': lay,
                if (fz != null && fileKind == 'image') ...{
                  if (fz['ela'] is Map) 'ela': fz['ela'],
                  if (fz['screenshot'] != null) 'screenshot': fz['screenshot'] == true,
                  if (fz['camera'] != null) 'camera': fz['camera'] == true,
                  if (fz['width'] is num) 'width': fz['width'],
                  if (fz['height'] is num) 'height': fz['height'],
                },
                if (fz != null && fileKind == 'pdf') ...{
                  if (fz['fonts'] is Map) 'fonts': fz['fonts'],
                  if (fz['whiteBoxes'] is num) 'whiteBoxes': fz['whiteBoxes'],
                },
              },
        'aadhaarQr': q == null || q['decoded'] != true
            ? null
            : <String, dynamic>{
                'decoded': true,
                'oldXml': q['oldXml'] == true,
                'signatureChecked': q['signatureChecked'] == true,
                'signatureValid': q['signatureValid'],
                'name': q['name'],
                'dob': q['dob'],
                'gender': q['gender'],
                'last4': q['last4'],
              },
      };
      final r = await Native.instance.analyzeDocument(input);
      if (mounted) setState(() => result = r['level'] is Map ? r : null);
    } on PlatformException {
      if (mounted) setState(() => note = () => tr('The check failed.'));
    } catch (_) {
      // Malformed engine output (FormatException / TypeError): same message, never an unhandled error.
      if (mounted) setState(() => note = () => tr('The check failed.'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// "Wrong type?": the user picks the right type and the check runs again.
  Future<void> _chooseType() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.8),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(tr('What is this document?'), style: Theme.of(c).textTheme.titleLarge),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_rounded),
              title: Text(tr('Let the app decide')),
              trailing: chosenType == null ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(c, 'auto'),
            ),
            for (final k in docTypeKeys)
              ListTile(
                leading: Icon(docTypeIcon(k)),
                title: Text(docTypeLabel(k)),
                trailing: chosenType == k ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.pop(c, k),
              ),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => chosenType = picked == 'auto' ? null : picked);
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = (result?['info'] as Map?)?.cast<String, dynamic>() ?? {};
    final n = note;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Check a document')), actions: const [LanguageButton()]),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        Panel(
          color: SL.bg(context, 'safe'),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_rounded, color: SL.fg(context, 'safe')),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr('Read on this device. Documents are never uploaded or saved, and Aadhaar numbers are hidden.'),
                style: TextStyle(color: SL.fg(context, 'safe'), fontWeight: FontWeight.w600, height: 1.4),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Panel(
          color: SL.bg(context, 'warning'),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_rounded, color: SL.fg(context, 'warning')),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr('Always cross-check. This check only looks for warning signs and can be wrong. Before you trust any ID, bank statement or letter, verify it on the official website or with the issuer.'),
                style: TextStyle(color: SL.fg(context, 'warning'), fontWeight: FontWeight.w600, height: 1.4),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        if (preview != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: Image.memory(preview!, fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),
          const SizedBox(height: 10),
        ] else if (fileKind == 'pdf') ...[
          Panel(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(Icons.picture_as_pdf_rounded, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(fileName ?? 'PDF', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton.icon(
          onPressed: busy ? null : _pickFile,
          icon: const Icon(Icons.upload_file_rounded),
          label: Text(tr('Choose a file (PDF or photo)')),
        ),
        if (!kIsWeb) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : _takePhoto,
            icon: const Icon(Icons.photo_camera_rounded),
            label: Text(tr('Take a photo')),
          ),
        ],
        if (n != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(n(), style: TextStyle(color: SL.fg(context, 'warning')))),
        const SizedBox(height: 14),
        TextField(
          controller: words,
          minLines: 4,
          maxLines: 12,
          inputFormatters: [LengthLimitingTextInputFormatter(50000)],
          decoration: InputDecoration(
            labelText: tr('What the document says'),
            hintText: tr('e.g. the name, ID number, dates and amounts as printed'),
            helperText: tr('Filled in automatically where possible. Fix any misread numbers or names.'),
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: busy ? null : _check,
          icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fact_check_rounded),
          label: Text(busy ? tr('Checking…') : tr('Check document')),
        ),
        if (result != null) ...[
          const SizedBox(height: 22),
          _DetectedHeader(
            detected: (info['detected'] as Map?)?.cast<String, dynamic>(),
            chosenType: chosenType,
            onWrongType: busy ? null : _chooseType,
          ),
          const SizedBox(height: 12),
          _FoundCard(info: info, fileName: fileName, editor: imageEditor, qrUnreadable: qrUnreadable, layout: layout, forensic: forensic),
          const SizedBox(height: 12),
          VerdictView(result: result!),
          const SizedBox(height: 12),
          Panel(
            color: SL.bg(context, 'warning'),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.verified_user_rounded, color: SL.fg(context, 'warning')),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Always verify on official sites'), style: TextStyle(color: SL.fg(context, 'warning'), fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(tr('This result is only a guide, not proof. Before you pay, sign, lend, hire or share anything, confirm the document with the official source: UIDAI for Aadhaar, the Income Tax portal for PAN, Passport Seva for passports, and your bank\'s net banking or branch for statements.'), style: TextStyle(color: SL.fg(context, 'warning'), height: 1.4)),
                ]),
              ),
            ]),
          ),
        ] else ...[
          SectionLabel(tr('Common fake-document tricks')),
          Panel(
            child: Text(
              [
                tr('Bank statements typed in Word or edited in a PDF app to show more money.'),
                tr('Aadhaar or PAN cards with a changed number, name or photo.'),
                tr('"Police", "RBI" or "court" letters that ask you to pay to close a case.'),
                tr('Job offer or loan letters that ask for a fee or deposit first.'),
              ].map((l) => '• $l').join('\n'),
              style: const TextStyle(height: 1.6),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Document types the app can recognise (keys from the engine's info.detected), for the "Wrong type?" list.
const docTypeKeys = [
  'aadhaar',
  'pan',
  'passport',
  'voter_id',
  'driving_licence',
  'bank_statement',
  'cheque',
  'salary_slip',
  'itr',
  'gst_certificate',
  'utility_bill',
  'invoice',
  'offer_letter',
  'legal_notice',
  'payment_screenshot',
  'certificate',
  'letter',
];

String docTypeLabel(String key) {
  switch (key) {
    case 'aadhaar':
      return tr('Aadhaar card');
    case 'pan':
      return tr('PAN card');
    case 'passport':
      return tr('Passport');
    case 'voter_id':
      return tr('Voter ID card');
    case 'driving_licence':
      return tr('Driving licence');
    case 'bank_statement':
      return tr('Bank statement');
    case 'cheque':
      return tr('Cheque');
    case 'salary_slip':
      return tr('Salary slip');
    case 'itr':
      return tr('Income tax return (ITR)');
    case 'gst_certificate':
      return tr('GST certificate');
    case 'utility_bill':
      return tr('Electricity, water or phone bill');
    case 'invoice':
      return tr('Invoice or bill');
    case 'offer_letter':
      return tr('Job offer letter');
    case 'legal_notice':
      return tr('Legal or police notice');
    case 'payment_screenshot':
      return tr('Payment screenshot');
    case 'certificate':
      return tr('Certificate');
    case 'letter':
      return tr('Letter or notice');
    default:
      return tr('Other document');
  }
}

IconData docTypeIcon(String key) {
  switch (key) {
    case 'aadhaar':
      return Icons.badge_rounded;
    case 'pan':
      return Icons.credit_card_rounded;
    case 'passport':
      return Icons.public_rounded;
    case 'voter_id':
      return Icons.how_to_vote_rounded;
    case 'driving_licence':
      return Icons.directions_car_rounded;
    case 'bank_statement':
      return Icons.account_balance_rounded;
    case 'cheque':
      return Icons.payments_rounded;
    case 'salary_slip':
      return Icons.request_quote_rounded;
    case 'itr':
      return Icons.receipt_long_rounded;
    case 'gst_certificate':
      return Icons.verified_rounded;
    case 'utility_bill':
      return Icons.bolt_rounded;
    case 'invoice':
      return Icons.receipt_rounded;
    case 'offer_letter':
      return Icons.work_rounded;
    case 'legal_notice':
      return Icons.gavel_rounded;
    case 'payment_screenshot':
      return Icons.phone_android_rounded;
    case 'certificate':
      return Icons.workspace_premium_rounded;
    case 'letter':
      return Icons.mail_rounded;
    default:
      return Icons.help_outline_rounded;
  }
}

/// "Detected: PAN card" header with how sure the app is, and a "Wrong type?" button.
class _DetectedHeader extends StatelessWidget {
  const _DetectedHeader({required this.detected, required this.chosenType, required this.onWrongType});
  final Map<String, dynamic>? detected;
  final String? chosenType;
  final VoidCallback? onWrongType;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final o = chosenType;
    final key = o ?? '${detected?['key'] ?? 'unknown'}';
    final known = key != 'unknown' && key.isNotEmpty;
    final conf = '${detected?['confidence'] ?? ''}';
    final String sure;
    switch (conf) {
      case 'high':
        sure = tr('Sure');
        break;
      case 'medium':
        sure = tr('Fairly sure');
        break;
      default:
        sure = tr('Not sure');
    }
    final title = o != null
        ? tr('Checked as: {type}', {'type': docTypeLabel(key)})
        : known
            ? tr('Detected: {type}', {'type': docTypeLabel(key)})
            : tr('Couldn\'t tell what kind of document this is');
    return Panel(
      color: cs.primary.withAlpha(18),
      borderColor: cs.primary.withAlpha(70),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: cs.primary.withAlpha(36), borderRadius: BorderRadius.circular(14)),
            child: Icon(docTypeIcon(key), color: cs.primary, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.25)),
              const SizedBox(height: 2),
              Text(
                o != null ? tr('You chose this type.') : (known ? sure : tr('General checks were used.')),
                style: TextStyle(fontSize: 13, color: cs.onSurface.withAlpha(160), fontWeight: FontWeight.w600),
              ),
            ]),
          ),
        ]),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onWrongType, child: Text(tr('Wrong type?'))),
        ),
      ]),
    );
  }
}

class _FoundCard extends StatelessWidget {
  const _FoundCard({required this.info, this.fileName, this.editor, this.qrUnreadable = false, this.layout, this.forensic});
  final Map<String, dynamic> info;
  final String? fileName, editor;
  final bool qrUnreadable;
  final Map<String, dynamic>? layout, forensic;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final file = (info['file'] as Map?)?.cast<String, dynamic>() ?? {};
    final kind = file['kind'] as String?;
    final ids = (info['ids'] as List? ?? []).whereType<Map>().toList();
    final st = (info['statement'] as Map?)?.cast<String, dynamic>();
    final pp = (info['passport'] as Map?)?.cast<String, dynamic>();
    final q = (info['qr'] as Map?)?.cast<String, dynamic>();
    final revs = (file['revisions'] as num?)?.toInt() ?? 0;

    final sections = <Widget>[];
    void section(String title, List<Widget> rows) {
      if (rows.isEmpty) return;
      sections.add(Padding(
        padding: EdgeInsets.only(top: sections.isEmpty ? 4 : 14, bottom: 2),
        child: Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary)),
      ));
      sections.addAll(rows);
    }

    // ---- the file
    section(tr('The file'), [
      _Row(tr('Checked as'), _docTypeWord('${info['docType'] ?? ''}')),
      if (kind != null) _Row(tr('File'), fileName ?? (kind == 'pdf' ? 'PDF' : tr('Photo'))),
      if (kind == 'pdf') _Row(tr('Program recorded in the file'), (file['program'] as String?) ?? tr('None recorded')),
      if (kind == 'pdf' && file['created'] != null) _Row(tr('Created'), _when('${file['created']}')),
      if (kind == 'pdf' && file['modified'] != null) _Row(tr('Modified'), _when('${file['modified']}')),
      if (kind == 'pdf') _Row(tr('Edits recorded'), revs > 1 ? '${revs - 1}' : tr('None')),
      if (kind == 'image')
        _Row(tr('Photo editor in file'), editor != null ? tr('Yes, saved by a photo-editing app') : tr('None found (normal for forwarded images)')),
      ..._forensicRows(context, kind),
    ]);

    // ---- ID numbers
    section(tr('Numbers found'), [
      for (final id in ids)
        _Row(
          _idLabel('${id['type']}'),
          '${id['value']}  ${id['valid'] == true ? '✓ ${tr('valid')}' : '✗ ${tr('fails check')}'}',
          color: SL.fg(context, id['valid'] == true ? 'safe' : 'danger'),
        ),
    ]);

    // ---- bank statement
    if (st != null) {
      final ok = st['summaryOk'];
      final bad = (st['mismatched'] as num?)?.toInt() ?? 0;
      section(tr('Bank statement'), [
        _Row(tr('Rows checked'), '${st['checked'] ?? 0}'),
        _Row(tr('Rows that don\'t add up'), '$bad', color: bad > 0 ? SL.fg(context, 'danger') : null),
        _Row(
          tr('Totals'),
          ok == null ? tr('Not found') : (ok == true ? '✓ ${tr('Add up')}' : '✗ ${tr('Don\'t add up')}'),
          color: ok == null ? null : SL.fg(context, ok == true ? 'safe' : 'danger'),
        ),
      ]);
    }

    // ---- passport
    if (pp != null) {
      section(tr('Passport'), [
        _Row(tr('Passport number'), '${pp['number'] ?? ''}'),
        if (pp['country'] != null) _Row(tr('Country'), '${pp['country']}'),
        if (pp['dob'] != null) _Row(tr('Date of birth'), '${pp['dob']}'),
        if (pp['expiry'] != null) _Row(tr('Expiry date'), '${pp['expiry']}'),
      ]);
    }

    // ---- Aadhaar QR
    if (q != null) {
      final String sig;
      final String level;
      if (q['oldXml'] == true) {
        sig = tr('Old QR without a signature');
        level = 'warning';
      } else if (q['signatureChecked'] == true && q['signatureValid'] == true) {
        sig = '✓ ${tr('Verified: signed by UIDAI')}';
        level = 'safe';
      } else if (q['signatureChecked'] == true) {
        sig = '✗ ${tr('Not verified: signature is not valid')}';
        level = 'danger';
      } else {
        sig = tr('Not checked on this device');
        level = 'warning';
      }
      section(tr('Aadhaar QR'), [
        _Row(tr('Signature'), sig, color: SL.fg(context, level)),
        if (q['name'] != null) _Row(tr('Name'), '${q['name']}'),
        if (q['dob'] != null) _Row(tr('Date of birth'), '${q['dob']}'),
        if (q['gender'] != null) _Row(tr('Gender'), _genderWord('${q['gender']}')),
        if (q['last4'] != null) _Row(tr('Aadhaar number'), 'XXXX XXXX ${q['last4']}'),
      ]);
    } else if (qrUnreadable) {
      section(tr('Aadhaar QR'), [
        _Row(tr('Signature'), tr('Found, but it couldn\'t be read here. Use UIDAI\'s official QR scanner app.')),
      ]);
    }

    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('What we found'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        ...sections,
      ]),
    );
  }

  /// What the file-level checks found: text alignment, fonts, white boxes, screenshot or camera photo, edited areas.
  List<Widget> _forensicRows(BuildContext context, String? kind) {
    final warn = SL.fg(context, 'warning');
    final rows = <Widget>[];
    final lay = layout;
    if (lay != null && lay['checked'] == true) {
      final odd = (lay['odd'] as num?)?.toInt() ?? 0;
      rows.add(_Row(
        tr('Text alignment'),
        odd > 0 ? tr('{n} words look out of line', {'n': odd}) : tr('Looks even'),
        color: odd > 0 ? warn : null,
      ));
      final samples = ((lay['samples'] as List?) ?? const []).map((e) => '$e').where((e) => e.isNotEmpty).take(5).toList();
      if (odd > 0 && samples.isNotEmpty) rows.add(_Row(tr('For example'), samples.join(', ')));
    }
    final fz = forensic;
    if (fz == null) return rows;
    if (kind == 'pdf') {
      final fonts = (fz['fonts'] as Map?)?.cast<String, dynamic>();
      if (fonts != null && fonts['checked'] == true) {
        final rare = (fonts['rare'] as List?) ?? const [];
        final count = (fonts['count'] as num?)?.toInt() ?? 0;
        rows.add(_Row(
          tr('Fonts'),
          rare.isNotEmpty ? tr('A font used only for a few numbers') : tr('{n} fonts, nothing unusual', {'n': count}),
          color: rare.isNotEmpty ? SL.fg(context, 'danger') : null,
        ));
      }
      final wb = (fz['whiteBoxes'] as num?)?.toInt();
      if (wb != null) {
        rows.add(_Row(tr('White boxes over content'), wb > 0 ? '$wb' : tr('None'), color: wb > 0 ? SL.fg(context, 'danger') : null));
      }
    } else if (kind == 'image') {
      if (fz['screenshot'] == true) {
        rows.add(_Row(tr('Type of image'), tr('Screenshot, not original'), color: warn));
      } else if (fz['camera'] == true) {
        rows.add(_Row(tr('Type of image'), tr('Photo taken with a camera')));
      }
      final w = (fz['width'] as num?)?.toInt(), h = (fz['height'] as num?)?.toInt();
      if (w != null && h != null && w > 0 && h > 0) rows.add(_Row(tr('Image size'), '$w × $h'));
      final ela = (fz['ela'] as Map?)?.cast<String, dynamic>();
      if (ela != null && ela['checked'] == true) {
        final score = (ela['score'] as num?)?.toDouble() ?? 0;
        final spots = (ela['hotspots'] as num?)?.toInt() ?? 0;
        final flagged = score >= 0.6 && spots >= 1;
        rows.add(_Row(tr('Signs of editing'), flagged ? tr('Some areas may have been changed') : tr('None found'), color: flagged ? warn : null));
      }
    }
    return rows;
  }

  static String _when(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}, ${two(d.hour)}:${two(d.minute)}';
  }

  static String _idLabel(String type) {
    switch (type) {
      case 'aadhaar':
        return 'Aadhaar';
      case 'pan':
        return 'PAN';
      case 'gstin':
        return 'GSTIN';
      case 'ifsc':
        return 'IFSC';
      case 'passport':
        return tr('Passport');
      default:
        return type;
    }
  }

  static String _docTypeWord(String t) {
    switch (t) {
      case 'id':
        return tr('ID card');
      case 'passport':
        return tr('Passport');
      case 'statement':
        return tr('Bank statement');
      case 'letter':
        return tr('Letter or notice');
      default:
        return t;
    }
  }

  static String _genderWord(String g) {
    switch (g) {
      case 'M':
        return tr('Male');
      case 'F':
        return tr('Female');
      case 'T':
        return tr('Transgender');
      default:
        return g;
    }
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(150)))),
          Expanded(child: SelectableText(value, style: TextStyle(fontWeight: FontWeight.w600, color: color))),
        ]),
      );
}
