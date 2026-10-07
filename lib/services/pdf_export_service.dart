import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/constants.dart';

/// Renders a simple title + generated-at header + data table as a PDF and
/// hands it to the platform share sheet — used by the audit trail's
/// "Export PDF" action for each of its tabs.
///
/// The default PDF font (Helvetica) can't render the peso sign — it prints
/// as a broken-glyph box instead (₱150 -> "☒150") — same charset limit
/// PrinterService works around for 58 mm thermal receipts. Free-text audit
/// descriptions (e.g. "fee set to ₱200") are written all over the app with
/// the real ₱ character already baked in, so rather than relying on every
/// call site to remember a PDF-safe format, every string that reaches this
/// table (title, headers, cells, summary) is sanitized once here — see
/// [_pdfSafe].
class PdfExportService {
  PdfExportService._();

  /// Swaps characters Helvetica can't render for a PDF-safe stand-in.
  /// Currently just the peso sign -> "PHP " (matching PrinterService's own
  /// receipt convention), extend here if another glyph turns up broken.
  static String _pdfSafe(String s) => s.replaceAll('₱', 'PHP ');

  /// Barangay seal for the letterhead — loaded once and cached (an asset
  /// read per export is wasted work for bytes that never change). Null
  /// means the asset failed to load; the letterhead still prints the org
  /// name/address text either way, just without the seal image.
  static pw.MemoryImage? _logoCache;

  static Future<pw.MemoryImage?> _loadLogo() async {
    final cached = _logoCache;
    if (cached != null) return cached;
    try {
      final bytes = await rootBundle.load('assets/icon/logo.png');
      final logo = pw.MemoryImage(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      _logoCache = logo;
      return logo;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> exportTable({
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
    /// Label/value pairs (e.g. "Total transactions" / "42", "Total
    /// collected" / "PHP 12,340") printed in a summary block right after
    /// the table — omitted entirely when there's nothing to total, e.g.
    /// the activity/access logs.
    List<MapEntry<String, String>> summary = const [],
    /// The date range the rows cover, already labelled by the caller (e.g.
    /// "Period: Sep 1, 2026 - Sep 24, 2026"), printed under the title so a printed report says which days it's
    /// for — omitted when the export isn't limited to a date range.
    String? period,
    /// Share sheet (default) or save straight to the phone's Downloads —
    /// see [PdfExportAction].
    PdfExportAction action = PdfExportAction.share,
  }) async {
    final safeTitleText = _pdfSafe(title);
    final safePeriod = period == null ? null : _pdfSafe(period);
    final safeHeaders = headers.map(_pdfSafe).toList();
    final safeRows = rows.map((r) => r.map(_pdfSafe).toList()).toList();
    final safeSummary = summary
        .map((e) => MapEntry(_pdfSafe(e.key), _pdfSafe(e.value)))
        .toList();
    final logo = await _loadLogo();

    final doc = pw.Document();
    final generatedAt =
        DateFormat('MMM d, yyyy · hh:mm a').format(DateTime.now());

    doc.addPage(
      pw.MultiPage(
        // Wide tables (e.g. Transaction Logs with collector + payment
        // columns) get landscape so cells stay readable.
        pageFormat: headers.length > 8
            ? PdfPageFormat.a4.landscape
            : PdfPageFormat.a4,
        // Letterhead: seal + org name/address, repeated on every page —
        // the report title/generated-at/record-count sits below its own
        // divider so the letterhead reads as the issuing authority and the
        // title block as which report this specific export is.
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                if (logo != null) ...[
                  pw.SizedBox(width: 46, height: 46, child: pw.Image(logo)),
                  pw.SizedBox(width: 12),
                ],
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(kOrgName,
                          style: pw.TextStyle(
                              fontSize: 16,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColors.teal700)),
                      pw.Text(kOrgAddress,
                          style: const pw.TextStyle(
                              fontSize: 9, color: PdfColors.grey700)),
                    ],
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Divider(color: PdfColors.grey400, thickness: 0.6),
            pw.SizedBox(height: 8),
            pw.Text(safeTitleText,
                style:
                    pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            if (safePeriod != null) ...[
              pw.SizedBox(height: 2),
              pw.Text(safePeriod,
                  style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.teal700)),
            ],
            pw.SizedBox(height: 2),
            pw.Text(
                'Generated $generatedAt · ${rows.length} record${rows.length == 1 ? '' : 's'}',
                style:
                    const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            pw.SizedBox(height: 12),
          ],
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: safeHeaders,
            data: safeRows,
            headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 9,
                color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.teal700),
            cellStyle: const pw.TextStyle(fontSize: 8.5),
            cellHeight: 22,
            cellAlignment: pw.Alignment.centerLeft,
            oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
          ),
          if (safeSummary.isNotEmpty) ...[
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  for (final entry in safeSummary)
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 2),
                      child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text(entry.key,
                              style: pw.TextStyle(
                                  fontSize: 10,
                                  fontWeight: pw.FontWeight.bold)),
                          pw.Text(entry.value,
                              style: pw.TextStyle(
                                  fontSize: 10,
                                  fontWeight: pw.FontWeight.bold,
                                  color: PdfColors.teal700)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final safeTitle =
        title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final filename = '${safeTitle}_$stamp.pdf';
    final bytes = await doc.save();
    if (action == PdfExportAction.download) {
      return _download(bytes, filename);
    }
    await Printing.sharePdf(bytes: bytes, filename: filename);
    return null;
  }

  /// Saves [bytes] where the person can find it again later and returns a
  /// human-readable location for the success message. On Android that's
  /// Download/PayPark via MediaStore (this app's target SDK has no direct
  /// public-folder file access — same route VehicleDocumentCache's backup
  /// uses). Elsewhere (web/desktop) the browser/OS share flow already
  /// lands as a regular download, so it's reused as-is.
  static Future<String?> _download(Uint8List bytes, String filename) async {
    if (kIsWeb || !Platform.isAndroid) {
      await Printing.sharePdf(bytes: bytes, filename: filename);
      return filename;
    }
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/$filename');
    await tempFile.writeAsBytes(bytes);
    // saveFile copies from the temp path and deletes it itself.
    final info = await MediaStore().saveFile(
      tempFilePath: tempFile.path,
      dirType: DirType.download,
      dirName: DirName.download,
    );
    if (info == null) throw Exception('Could not save to Downloads');
    return 'Download/${MediaStore.appFolder}/${info.name}';
  }
}

/// What "Export PDF" does with the finished file.
enum PdfExportAction {
  /// Opens the phone's share sheet (Messenger, Gmail, Drive, print…).
  share,

  /// Saves straight into the phone's Downloads folder.
  download,
}
