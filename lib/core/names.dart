/// Display form of a person's name: each word capitalized and a lone
/// middle initial given a period — "carlos s espin" → "Carlos S. Espin".
/// Names are stored however they were typed; this is applied when they're
/// shown or printed, so old and new records read the same.
String formatPersonName(String raw) {
  final words = raw.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final out = <String>[];
  final list = words.toList();
  for (var i = 0; i < list.length; i++) {
    final w = list[i];
    final initial = w.replaceAll('.', '');
    final isMiddleInitial =
        initial.length == 1 && i > 0 && i < list.length - 1;
    if (isMiddleInitial) {
      out.add('${initial.toUpperCase()}.');
    } else {
      out.add(w[0].toUpperCase() + w.substring(1).toLowerCase());
    }
  }
  return out.join(' ');
}
