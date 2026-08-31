/// Username normalization + the synthetic-email scheme that lets Firebase
/// Auth's email/password provider stand in for username+password sign-in
/// — replaces the old phone-number-based scheme (core/phone.dart) now that
/// accounts aren't tied to a phone number at all. See
/// YosRepository.emailForUsername, which just delegates here.
library;

/// Normalizes a collector-chosen username: trims and lowercases so two
/// people can't register visually-identical handles that differ only by
/// case or stray whitespace, then validates it's 3-20 characters of
/// letters/digits/underscore/dot. Throws [FormatException] on anything
/// else, so a typo (or an attempt to sneak in `@`/spaces that would land
/// inside the synthetic email) surfaces as a real validation error instead
/// of a bogus value silently reaching Firebase.
String normalizeUsername(String raw) {
  final trimmed = raw.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9._]{3,20}$').hasMatch(trimmed)) {
    throw FormatException('Not a valid username: $raw');
  }
  return trimmed;
}

/// Deterministic, never-shown Firebase Auth email for an already-normalized
/// username. Same `@paypark.local` scheme the app has always used — do not
/// change the domain, that would orphan every existing account. Uniqueness
/// falls naturally out of Firebase Auth's own email-already-in-use check,
/// since two different usernames can never normalize to the same email.
String syntheticEmailForUsername(String username) =>
    '$username@paypark.local';
