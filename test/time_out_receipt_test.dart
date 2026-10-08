import 'package:flutter_test/flutter_test.dart';
import 'package:yos_app/core/constants.dart';
import 'package:yos_app/services/printer_service.dart';

void main() {
  TimeOutReceipt sample({String driver = 'Ruel C Binasbas'}) => TimeOutReceipt(
        letterhead: kReceiptLetterhead,
        ordinance: kOrdinanceRef,
        trackingId: 'POB-20261008-79E3CC',
        timeIn: DateTime(2026, 10, 8, 14, 35),
        timeOut: DateTime(2026, 10, 8, 17, 41),
        plateNumber: 'TAT471',
        driverName: driver,
        vehicleType: 'Trailer Truck',
        zoneId: 'savemore',
        breakdown: const [('First 3 Hours', 200), ('Extra 1 Hour x 25', 25)],
        totalPaid: 225,
        paymentMethod: 'GCash',
        paymentRef: '1012345678901',
        collectorName: 'Carlos S. Espin',
        points: (earned: 2, redeemed: 0, balance: 14, discountPesos: 0),
      );

  test('every line fits the 58 mm paper (32 columns)', () {
    final lines = PrinterService.instance.timeOutReceiptLines(sample());
    for (final l in lines) {
      expect(l.length, lessThanOrEqualTo(PrinterService.lineWidth), reason: l);
    }
  });

  test('letterhead first, total paid, ordinance last', () {
    final lines = PrinterService.instance.timeOutReceiptLines(sample());
    expect(lines.first, 'BARANGAY SAN NICOLAS POBLACION');
    expect(lines.any((l) => l.startsWith('Date') && l.endsWith('Oct 8, 2026 05:41 PM')), isTrue);
    expect(lines.any((l) => l.startsWith('TOTAL PAID') && l.endsWith('PHP 225.00')), isTrue);
    expect(lines.any((l) => l.startsWith('Ref no.') && l.endsWith('1012345678901')), isTrue);
    expect(lines.last, 'Keep this receipt.');
    expect(lines.contains('Municipal Ordinance No. 2024-07'), isTrue);
  });

  test('a very long driver name keeps first and last name, and fits', () {
    // Like the old receipt, middle names shorten to initials on paper.
    const name = 'Maria Concepcion Dela Cruz Villanueva Santos';
    final lines =
        PrinterService.instance.timeOutReceiptLines(sample(driver: name));
    final text = lines.join(' ');
    for (final word in ['Maria', 'Santos']) {
      expect(text.contains(word), isTrue, reason: word);
    }
    for (final l in lines) {
      expect(l.length, lessThanOrEqualTo(PrinterService.lineWidth), reason: l);
    }
  });
}
