import 'package:flutter_test/flutter_test.dart';
import 'package:yos_app/services/document_ocr.dart';

void main() {
  group('parseOrCr plate detection', () {
    test('finds the plate when label and value share a line', () {
      const text = 'PLATE NO. FAQ1243\nENGINE NO. 4N15UKC1087';
      expect(DocumentOcr.parseOrCr(text).plate, 'FAQ1243');
    });

    // Mirrors a real LTO Certificate of Registration: a whole row of
    // column headers reads as one OCR line, then the matching row of
    // values reads as the next line — this used to fall through to the
    // whole-document fallback and could latch onto noise from elsewhere
    // on the page instead of the real plate.
    test('finds the plate in a table layout (labels then values)', () {
      const text = '''
CERTIFICATE OF REGISTRATION
PLATE NO. ENGINE NO. CHASSIS NO. VIN
FAQ1243 4N15UKC1087 MMBJLKK10PH068069 MMBJLKK10PH068069
FILE NO. VEHICLE TYPE VEHICLE CATEGORY MAKE/BRAND
060123000383014 UTILITY VEHICLE N1 MITSUBISHI
OWNER'S NAME
MARGARET ANN GALOTERA ELEFERIA
''';
      expect(DocumentOcr.parseOrCr(text).plate, 'FAQ1243');
    });

    test('never latches onto the chassis/engine/VIN numbers', () {
      const text = '''
ENGINE NO.
4N15UKC1087
CHASSIS NO.
MMBJLKK10PH068069
VIN
MMBJLKK10PH068069
''';
      // None of these should ever be mistaken for a plate — the doc has
      // no plate at all in this fragment, so the honest answer is null,
      // not a wrong guess.
      expect(DocumentOcr.parseOrCr(text).plate, isNull);
    });

    test('does not let a table row drag in the next column\'s header',
        () {
      // If the labeled-match regex ever again captures across a table
      // boundary, it should still fail the shape check rather than
      // pretend "ENGINE NO" is a plate.
      const text = 'PLATE NO. ENGINE NO. CHASSIS NO.';
      expect(DocumentOcr.parseOrCr(text).plate, isNull);
    });
  });
}
