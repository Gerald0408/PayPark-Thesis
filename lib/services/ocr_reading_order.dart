import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Reconstructs recognized text in genuine top-to-bottom, left-to-right
/// reading order using each line's actual position on the page, instead
/// of trusting RecognizedText.text's own block order. ML Kit groups text
/// into blocks by visual proximity, not by row — on a two-column layout
/// like a PH driver's license (a label and its value sitting side by
/// side, or two unrelated fields sharing a horizontal band), that block
/// order routinely interleaves lines that have nothing to do with each
/// other, which is what "the text isn't aligned" was actually seeing.
///
/// Every recognized line is flattened, sorted by vertical position, then
/// grouped into rows with any other line whose vertical center falls
/// within about 60% of a line-height of the current row — narrow enough
/// that a genuinely new row (the next label down) still starts a new
/// line, wide enough to tolerate the slight vertical jitter between two
/// lines that are really on the same printed row. Each row is then
/// sorted left-to-right before being joined, so a label and its value
/// come out in the right order even when ML Kit read them as separate
/// blocks.
///
/// Shared by DocumentScanScreen's camera capture and
/// VehicleAttachmentScreen's gallery import — both feed a photo through
/// ML Kit and need the same reading-order fix-up before DocumentOcr ever
/// sees the text.
class OcrReadingOrder {
  OcrReadingOrder._();

  static String reconstruct(RecognizedText recognized) {
    final lines = <TextLine>[
      for (final block in recognized.blocks) ...block.lines,
    ];
    if (lines.isEmpty) return recognized.text;
    lines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

    final rows = <List<TextLine>>[];
    for (final line in lines) {
      final lineMid = (line.boundingBox.top + line.boundingBox.bottom) / 2;
      if (rows.isNotEmpty) {
        final lastRow = rows.last;
        final rowMid = lastRow
                .map((l) => (l.boundingBox.top + l.boundingBox.bottom) / 2)
                .reduce((a, b) => a + b) /
            lastRow.length;
        final rowHeight =
            lastRow.map((l) => l.boundingBox.height).reduce((a, b) => a + b) /
                lastRow.length;
        if ((lineMid - rowMid).abs() < rowHeight * 0.6) {
          lastRow.add(line);
          continue;
        }
      }
      rows.add([line]);
    }

    final buffer = StringBuffer();
    for (final row in rows) {
      row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
      buffer.writeln(row.map((l) => l.text).join('   '));
    }
    return buffer.toString().trim();
  }
}
