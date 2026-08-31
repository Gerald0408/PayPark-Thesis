import '../models/registered_vehicle.dart';

/// "Does this text contain something shaped like a PH plate" matcher —
/// used by DocumentOcr when reading an OR/CR photo at registration time.
/// Vehicle entry itself is manual-only (no live camera plate scanner
/// anymore), so this is the one remaining consumer.
class PlateMatcher {
  PlateMatcher._();

  static final _shapes = <RegExp>[
    RegExp(r'([0-9]{3})[\s\-]?([A-Z]{3})'),
    RegExp(r'([A-Z]{3})[\s\-]?([0-9]{4})'),
    RegExp(r'([A-Z]{3})[\s\-]?([0-9]{3})'),
    RegExp(r'([0-9]{4})[\s\-]?([A-Z]{2})'),
    RegExp(r'([A-Z]{2})[\s\-]?([0-9]{4,5})'),
    RegExp(r'([A-Z])[\s\-]?([0-9]{5})'),
  ];

  /// Strips everything but letters, digits, spaces, dashes and newlines,
  /// and upper-cases — the shapes above only match against that reduced
  /// alphabet.
  static String clean(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9 \-\n]'), '');

  /// A handful of OCR's most common single-character confusions
  /// (O/0, I/1, S/5, B/8, ...) applied wholesale in each direction, so a
  /// plate misread in either direction still has a shot at matching.
  static List<String> _variants(String s) {
    final out = <String>[s];
    final d = s
        .replaceAll('O', '0')
        .replaceAll('Q', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('S', '5')
        .replaceAll('B', '8')
        .replaceAll('Z', '2');
    if (d != s) out.add(d);
    final l = s
        .replaceAll('0', 'O')
        .replaceAll('1', 'I')
        .replaceAll('5', 'S')
        .replaceAll('8', 'B');
    if (l != s) out.add(l);
    return out;
  }

  /// Best-scoring plate-shaped match anywhere in [text] (already run
  /// through [clean]), already normalized (see
  /// RegisteredVehicle.normalize) — or null if nothing plate-shaped was
  /// found. Prefers a tighter/more specific shape, a match that fills
  /// its whole candidate string, and one that still had its original
  /// separators (a real plate is usually printed with a space or dash),
  /// each nudging the score so the most plausible read wins when several
  /// shapes match.
  static String? bestMatch(String text) {
    final candidates = <MapEntry<String, int>>[];
    for (var i = 0; i < _shapes.length; i++) {
      for (final candidate in _variants(text)) {
        for (final m in _shapes[i].allMatches(candidate)) {
          final joined = '${m.group(1)}${m.group(2)}';
          if (RegExp(r'^(.)\1+$').hasMatch(joined)) continue;
          var score = 100 - i * 5 + joined.length * 3;
          if (m.start == 0 && m.end == candidate.length) score += 25;
          if (candidate == text) score += 15;
          if (m.group(0)!.contains(' ') || m.group(0)!.contains('-')) {
            score += 10;
          }
          candidates
              .add(MapEntry(RegisteredVehicle.normalize(joined), score));
        }
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.value.compareTo(a.value));
    return candidates.first.key;
  }
}
