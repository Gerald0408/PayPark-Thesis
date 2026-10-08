import 'package:flutter_test/flutter_test.dart';
import 'package:yos_app/services/payment_ref_ocr.dart';

void main() {
  test('GCash: label and grouped number on one line', () {
    const text = '''
Sent via GCash
Amount 85.00
Total Amount Sent PHP 85.00
Ref No. 1012 345 678901 Oct 8, 2026 5:41 PM
''';
    expect(PaymentRefOcr.parse(text), '1012345678901');
  });

  test('GCash: label and number on separate lines', () {
    const text = 'Ref No.\n1012 345 678901\nOct 8, 2026 5:41 PM';
    expect(PaymentRefOcr.parse(text), '1012345678901');
  });

  test('Maya: alphanumeric Reference ID', () {
    const text = '''
Payment successful
PHP 85.00
Reference ID
6A1B 2C3D 4E5F
Oct 8, 2026, 5:41 PM
''';
    expect(PaymentRefOcr.parse(text), '6A1B2C3D4E5F');
  });

  test('no label: falls back to a 13-digit number, not the phone number', () {
    const text = '''
JUAN D.
+63 917 123 4567
Amount 85.00
1012 345 678901
''';
    expect(PaymentRefOcr.parse(text), '1012345678901');
  });

  test('nothing that looks like a reference', () {
    const text = 'GCash\nAmount 85.00\n0917 123 4567';
    expect(PaymentRefOcr.parse(text), isNull);
  });
}
