import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Combines the captured document photos (driver's license, OR/CR) into
/// one multi-page PDF, each page sized to that photo's own pixel aspect
/// ratio rather than a fixed page size, so every page is exactly the
/// document it holds, not a photo floating inside a differently-shaped
/// page.
///
/// A real, self-contained document file — open-able and shareable with
/// any PDF reader, not just this app's own `Image.file`/`Image.network`
/// rendering path — is what makes a vehicle's captured documents
/// something a collector can trust to stay viewable, independent of how
/// they got here. One combined file (rather than a separate file per
/// document) is also what lets Vehicle Details show a single "Documents"
/// button instead of two.
class DocumentPdf {
  DocumentPdf._();

  /// [jpegImages] in page order — a null entry is skipped (that document
  /// just hasn't been captured yet), and an empty/all-null list throws
  /// rather than returning a pointless zero-page PDF.
  static Future<Uint8List> fromJpegImages(List<Uint8List?> jpegImages) async {
    final doc = pw.Document();
    var pageCount = 0;
    for (final bytes in jpegImages) {
      if (bytes == null) continue;
      final decoded = img.decodeImage(bytes);
      // Falls back to a plausible portrait-document ratio on the rare
      // decode failure — the page just won't perfectly match the photo's
      // own aspect ratio, still far better than dropping the page outright.
      final width = (decoded?.width ?? 1000).toDouble();
      final height = (decoded?.height ?? 1400).toDouble();
      final image = pw.MemoryImage(bytes);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(width, height, marginAll: 0),
          build: (context) => pw.Image(image, fit: pw.BoxFit.fill),
        ),
      );
      pageCount++;
    }
    if (pageCount == 0) {
      throw ArgumentError('At least one document image is required.');
    }
    return doc.save();
  }
}
