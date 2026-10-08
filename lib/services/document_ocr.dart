import '../core/constants.dart';
import 'plate_matcher.dart';

/// Best-effort field extraction from OCR'd text off a photographed
/// document. Real ID/registration layouts vary a lot and on-device OCR
/// garbles small print, so this is meant to save typing on a decent scan —
/// not to be trusted blindly. Every field it returns is a suggestion the
/// collector reviews in an already-editable form field, never a silent
/// write.
class DocumentOcr {
  DocumentOcr._();

  // Philippine driver's license number, e.g. "N01-23-456789".
  static final _licenseNoPattern = RegExp(r'\b[A-Z]\d{2}-\d{2}-\d{6}\b');

  static final _lastNameLabel = RegExp(
      r'(?:LAST\s*NAME|SURNAME)\s*[:\-]?\s*([A-Z][A-Za-z.\s]{1,40})',
      caseSensitive: false);

  static final _firstNameLabel = RegExp(
      r'(?:FIRST\s*NAME|GIVEN\s*NAME)\s*[:\-]?\s*([A-Z][A-Za-z.\s]{1,40})',
      caseSensitive: false);

  /// Fallback shape for a name that isn't clearly labeled: a bare
  /// "SURNAME, GIVEN NAME MIDDLE" line, common on ID cards where the
  /// label and value print on separate lines and OCR merges them.
  static final _commaNameLine = RegExp(
      r'^[A-Z][A-Z.\-]{1,25},\s*[A-Z][A-Za-z.\-\s]{1,40}$',
      multiLine: true);

  static ({String? name, String? licenseNumber}) parseDriverLicense(
      String text) {
    final licenseNumber = _licenseNoPattern.firstMatch(text)?.group(0);

    String? name;
    final last = _lastNameLabel.firstMatch(text)?.group(1)?.trim();
    final first = _firstNameLabel.firstMatch(text)?.group(1)?.trim();
    if (last != null && first != null) {
      name = '$first $last';
    } else {
      final line = _commaNameLine.firstMatch(text)?.group(0)?.trim();
      if (line != null) {
        final parts = line.split(',');
        if (parts.length == 2) {
          name = '${parts[1].trim()} ${parts[0].trim()}';
        }
      }
    }

    return (
      name: (name != null && name.trim().length > 3) ? _titleCase(name) : null,
      licenseNumber: licenseNumber,
    );
  }

  static final _plateLabel = RegExp(
      r'PLATE\s*(?:NO\.?|NUMBER)?\s*[:\-]?\s*([A-Z0-9\s\-]{4,10})',
      caseSensitive: false);

  /// Other numbered fields a CR/OR prints — engine no., chassis no., VIN,
  /// file no., O.R./C.R. serials, weights, year, piston displacement,
  /// power, amount paid. Lines carrying these labels are skipped when
  /// hunting for a plate-shaped fallback match (see [parseOrCr] step 3),
  /// since any one of these numbers is exactly the kind of thing that can
  /// coincidentally look plate-shaped after OCR noise — and unlike the
  /// plate, there's no shape-scoring trick that reliably tells them apart
  /// from a real plate once mislabeled.
  static final _otherNumberLabel = RegExp(
      r'ENGINE|CHASSIS|\bVIN\b|FILE\s*NO|O\.?R\.?\s*NO|C\.?R\.?\s*NO|'
      r'GROSS\s*WEIGHT|NET\s*WEIGHT|YEAR\s*(?:MODEL|REBUILT)|PISTON|'
      r'MAX\s*POWER|AMOUNT|OFFICE\s*CODE',
      caseSensitive: false);

  static final _ownerLabel = RegExp(
      r"(?:NAME\s*OF\s*OWNER|OWNER(?:'?S)?\s*NAME|OWNER)\s*[:\-]?\s*([A-Z][A-Za-z.,\s]{1,45})",
      caseSensitive: false);

  /// Plate-shaped match within one line, restricted to individual
  /// whitespace-separated tokens 5-8 characters long (a real PH plate,
  /// cleaned, is always in that range). Deliberately *not* just
  /// `PlateMatcher.bestMatch(clean(line))` on the whole line: an engine
  /// number like "4N15UKC1087" isn't itself plate-shaped, but the
  /// substring "UKC1087" buried inside it is — feeding the matcher the
  /// whole line lets it pluck that substring out and misreport it as the
  /// plate. Checking each token as its own complete, length-bounded
  /// candidate keeps a long serial number from ever being *partially*
  /// mistaken for one.
  static String? _plateInLine(String line) {
    for (final token in PlateMatcher.clean(line).split(RegExp(r'\s+'))) {
      if (token.length < 5 || token.length > 8) continue;
      final match = PlateMatcher.bestMatch(token);
      if (match != null) return match;
    }
    return null;
  }

  static ({String? plate, String? ownerName, String? vehicleTypeLabel})
      parseOrCr(String text) {
    final lines = text.split('\n');
    String? plate;

    // 1. Label and value on the same OCR line ("PLATE NO. FAQ1243") — the
    // easy case. Validated against PlateMatcher's own shapes rather than
    // just a length check, so a table layout that drags the *next*
    // column's header text into the capture (e.g. "ENGINE NO...") can't
    // slip through pretending to be the plate.
    final labeled = _plateLabel.firstMatch(text)?.group(1);
    if (labeled != null) {
      plate = PlateMatcher.bestMatch(PlateMatcher.clean(labeled));
    }

    // 2. Label found, but a table-formatted CR/OR often prints a whole
    // row of labels first ("PLATE NO. | ENGINE NO. | CHASSIS NO. | VIN")
    // and the matching row of values on a separate line below it — check
    // the next couple of lines *after* the one naming "PLATE" itself
    // (never that label line's own text — see _plateInLine's doc comment
    // for why a header line is actually dangerous to scan directly).
    if (plate == null) {
      final labelLine =
          lines.indexWhere((l) => l.toUpperCase().contains('PLATE'));
      if (labelLine != -1) {
        for (var i = labelLine + 1;
            i < lines.length && i <= labelLine + 3;
            i++) {
          if (_otherNumberLabel.hasMatch(lines[i])) continue;
          plate = _plateInLine(lines[i]);
          if (plate != null) break;
        }
      }
    }

    // 3. Last resort: every remaining line not naming one of the
    // document's other numbered fields (see _otherNumberLabel).
    // Deliberately still line-by-line, never the whole document collapsed
    // into one blob — splicing text across unrelated fields (a logo
    // fragment plus a stray digit run from somewhere else on the page) is
    // exactly how a false match gets manufactured.
    if (plate == null) {
      for (final line in lines) {
        if (_otherNumberLabel.hasMatch(line)) continue;
        plate = _plateInLine(line);
        if (plate != null) break;
      }
    }

    final owner = _ownerLabel.firstMatch(text)?.group(1)?.trim();

    final typeLabel = _matchVehicleType(text);

    return (
      plate: plate,
      ownerName: owner == null ? null : _titleCase(owner),
      vehicleTypeLabel: typeLabel,
    );
  }

  /// Maps an OR/CR's body-type text to one of this app's three
  /// [VehicleType] labels — still pure on-device pattern matching, no AI
  /// involved, just a wider vocabulary than a plain label-substring check.
  /// Philippine OR/CRs print either a plain body type ("TRICYCLE", "VAN",
  /// "TRUCK") or, less often, the LTO/UNECE classification code itself
  /// (e.g. "N1" for a light cargo pickup) — exact label names are checked
  /// first since they're the least likely to be a coincidental substring
  /// of something else on the page. More specific keywords (e.g. "CLOSED
  /// VAN") are listed before the plainer ones they'd otherwise collide
  /// with (e.g. "VAN"), since the first matching entry wins.
  static const _typeKeywords = <String, List<String>>{
    'Motorcycle': [
      'MOTORCYCLE',
      'SCOOTER',
      'TRICYCLE',
      'TRIKE',
      'L4',
      'L5',
    ],
    'Closed Van': [
      'CLOSED VAN',
      'JEEP',
      'SUV',
    ],
    'Forward / Elf': [
      'VAN',
      'AUV',
      'FORWARD',
      'ELF',
      'PICKUP',
      'PICK-UP',
      'UTILITY',
      'M1',
      'M2',
      'N1',
    ],
    'Trailer Truck': [
      '10 WHEELER',
      'TEN WHEELER',
      'TRAILER',
      'CARGO TRUCK',
      'DUMP TRUCK',
      'N2',
      'N3',
    ],
  };

  static String? _matchVehicleType(String text) {
    final upperText = text.toUpperCase();
    for (final t in VehicleType.values) {
      if (upperText.contains(t.label.toUpperCase())) return t.label;
    }
    for (final entry in _typeKeywords.entries) {
      for (final kw in entry.value) {
        if (upperText.contains(kw)) return entry.key;
      }
    }
    return null;
  }

  static String _titleCase(String s) => s
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}
