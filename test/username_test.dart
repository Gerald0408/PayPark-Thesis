import 'package:flutter_test/flutter_test.dart';
import 'package:yos_app/core/username.dart';

void main() {
  group('normalizeUsername', () {
    test('trims and lowercases', () {
      expect(normalizeUsername('  Juan.DelaCruz  '), 'juan.delacruz');
    });

    test('accepts letters, digits, dot, underscore', () {
      expect(normalizeUsername('juan_dela.cruz2'), 'juan_dela.cruz2');
    });

    test('rejects too-short input', () {
      expect(() => normalizeUsername('ab'), throwsFormatException);
    });

    test('rejects too-long input', () {
      expect(() => normalizeUsername('a' * 21), throwsFormatException);
    });

    test('rejects spaces', () {
      expect(() => normalizeUsername('juan cruz'), throwsFormatException);
    });

    test('rejects symbols that would break the synthetic email', () {
      expect(() => normalizeUsername('juan@cruz'), throwsFormatException);
    });
  });

  group('syntheticEmailForUsername', () {
    test('derives the @paypark.local address', () {
      expect(syntheticEmailForUsername('juan.delacruz'),
          'juan.delacruz@paypark.local');
    });
  });
}
