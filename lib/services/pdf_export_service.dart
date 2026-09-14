import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Renders a simple title + generated-at header + data table as a PDF and
/// hands it to the platform share sheet — used by the audit trail's
/// "Export PDF" action for each of its tabs.
///
/// The default PDF font (Helvetica) can't render the peso sign, so callers
/// should format money as "PHP 150" rather than "₱150" — same convention
/// PrinterService uses for 58 mm thermal receipts, which hit the same
/// charset limit.
class PdfExportService {
  PdfExportService._();

  static Future<void> exportTable({
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
  }) async {
    final doc = pw.Document();
    final generatedAt =
        DateFormat('MMM d, yyyy · hh:mm a').format(DateTime.now());

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title,
                style:
                    pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
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
            headers: headers,
            data: rows,
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
        ],
      ),
    );

    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final safeTitle =
        title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: '${safeTitle}_$stamp.pdf',
    );
  }
}
