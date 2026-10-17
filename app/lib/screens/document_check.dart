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
  const DocumentCheckScreen({super.key});

  @override
  State<DocumentCheckScreen> createState() => _DocumentCheckScreenState();
}

class _DocumentCheckScreenState extends State<DocumentCheckScreen> {
  /// Chip label (English, shown with tr()) and the docType sent to the engine.
  static const _types = [
    ['Auto-detect', 'auto'],
    ['Aadhaar / ID card', 'id'],
    ['Passport', 'passport'],
    ['PAN card', 'id'],
    ['Bank statement', 'statement'],
    ['Letter or notice', 'letter'],
  ];

  final words = TextEditingController();
  int typeIndex = 0;

  String? fileName;
  String? fileKind; // 'pdf' or 'image'
  Map<String, dynamic>? pdfMeta;
  String? imageEditor;
  Uint8List? preview; // photos only, kept in memory while this screen is open
  Map<String, dynamic>? qr; // Aadhaar QR details, in memory only
  bool qrUnreadable = false;

  Map<String, dynamic>? result;
  bool busy = false;
  String Function()? note; // built with tr() when shown, so it follows the language

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
    result = null;
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
      String Function()? n;
      if (path != null && !kIsWeb) {
        try {
          final r = await Native.instance.readImage(path, layout: true);
          text = (r['text'] as String?) ?? '';
          qrs = ((r['qr'] as List?) ?? const []).map((e) => '$e').toList();
          if (text.trim().isEmpty) n = () => tr('No words could be read in this photo. Type the important lines below.');
        } on PlatformException {
          n = () => tr('Couldn\'t read the words in this photo. Type the important lines below.');
        }
      } else {
        n = () => tr('In the browser the words in a photo can\'t be read. Type the important lines below.');
      }
      await _useImage(name: name, bytes: bytes, text: text, qrs: qrs, editor: ImageMeta.editorIn(bytes), readNote: n);
    } else {
      setState(() => note = () => tr('Choose a PDF or a photo (JPG or PNG).'));
    }
  }

  static bool _isPdf(Uint8List b) => b.length > 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46; // %PDF

  Future<void> _usePdf({required String name, required String? path, required Uint8List bytes}) async {
    final meta = PdfMeta.parse(bytes);
    var text = '';
    String Function()? n;
    if (path != null && !kIsWeb) {
      try {
        final r = await Native.instance.readPdf(path);
        text = '${r['text'] ?? ''}';
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
    String Function()? readNote,
  }) async {
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
      final input = <String, dynamic>{
        'text': t,
        'docType': _types[typeIndex][1],
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
        SectionLabel(tr('What kind of document?')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < _types.length; i++)
            ChoiceChip(
              label: Text(tr(_types[i][0])),
              selected: typeIndex == i,
              onSelected: busy
                  ? null
                  : (_) {
                      setState(() => typeIndex = i);
                      if (result != null) _check();
                    },
            ),
        ]),
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
          _FoundCard(info: info, fileName: fileName, editor: imageEditor, qrUnreadable: qrUnreadable),
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

class _FoundCard extends StatelessWidget {
  const _FoundCard({required this.info, this.fileName, this.editor, this.qrUnreadable = false});
  final Map<String, dynamic> info;
  final String? fileName, editor;
  final bool qrUnreadable;

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
