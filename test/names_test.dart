import 'package:flutter_test/flutter_test.dart';
import 'package:yos_app/core/names.dart';

void main() {
  test('names display with capitals and a middle-initial period', () {
    expect(formatPersonName('carlos s espin'), 'Carlos S. Espin');
    expect(formatPersonName('CARLOS S. ESPIN'), 'Carlos S. Espin');
    expect(formatPersonName('  juan   dela cruz '), 'Juan Dela Cruz');
    expect(formatPersonName('maria'), 'Maria');
  });
}
