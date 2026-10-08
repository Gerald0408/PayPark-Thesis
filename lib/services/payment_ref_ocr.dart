/// Pulls the reference number off a photographed GCash / Maya payment
/// screen (the driver's "sent" confirmation). Pure text parsing — no
/// ML Kit here — so it can be tested directly (see
/// test/payment_ref_ocr_test.dart). Like DocumentOcr, the result is a
/// suggestion that lands in the editable reference field for the
/// collector to check against the driver's screen, never a silent write.
class PaymentRefOcr {
  PaymentRefOcr._();

  // "Ref No.", "Ref. No:", "Reference No.", "Reference ID", "Reference
  // Number", "Ref #" — GCash prints "Ref No.", Maya "Reference ID".
  static final _label = RegExp(
      r'\bREF(?:ERENCE)?\.?\s*(?:NO|ID|NUMBER|#)\.?\s*[:#]?\s*',
      caseSensitive: false);

  // A reference split into groups by spaces, as both apps print it
  // ("1012 345 678901", "6A1B 2C3D 4E5F"). Every group has a digit, so
  // a date that follows on the same line ("Oct 8, 2026") isn't pulled in.
  static final _groups =
      RegExp(r'[A-Za-z]*\d[A-Za-z0-9]*(?:[ \-][A-Za-z]*\d[A-Za-z0-9]*)*');

  /// GCash: 13 digits. Maya: 12 letters/digits (sometimes all digits).
  /// Anything 8–20 characters with at least one digit is accepted after
  /// a label, so a format change doesn't silently stop working.
  static bool _plausible(String ref) =>
      ref.length >= 8 && ref.length <= 20 && RegExp(r'\d').hasMatch(ref);

  static String _clean(String s) =>
      s.replaceAll(RegExp(r'[ \-]'), '').toUpperCase();

  /// The reference number in [text], or null when none could be found.
  static String? parse(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // 1. After a "Ref No." / "Reference ID" label — on the same line, or
    //    the next line when the label and value are printed stacked.
    for (var i = 0; i < lines.length; i++) {
      final m = _label.firstMatch(lines[i]);
      if (m == null) continue;
      final rest = lines[i].substring(m.end);
      for (final candidate in [
        if (rest.isNotEmpty) rest,
        if (i + 1 < lines.length) lines[i + 1],
      ]) {
        final g = _groups.firstMatch(candidate);
        if (g == null) continue;
        final ref = _clean(g.group(0)!);
        if (_plausible(ref)) return ref;
      }
    }

    // 2. No label read — fall back to a GCash-shaped number: exactly 13
    //    digits on one line (spaces allowed). A mobile number (11 digits,
    //    or 12 with the 63 prefix) and amounts never have 13.
    for (final line in lines) {
      for (final g in RegExp(r'\d+(?: \d+)*').allMatches(line)) {
        final digits = g.group(0)!.replaceAll(' ', '');
        if (digits.length == 13) return digits;
      }
    }
    return null;
  }
}
