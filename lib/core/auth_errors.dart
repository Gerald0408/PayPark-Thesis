/// Central FirebaseAuthException -> collector-facing message mapping.
///
/// Every screen that touches username/password auth (register, login
/// reauth, change password) should route error codes through here instead
/// of writing its own switch — keeps the copy consistent and guarantees
/// the synthetic `@paypark.local` address (see core/username.dart) never
/// leaks into a message a collector reads.
library;

String authErrorMessage(String code) => switch (code) {
      'email-already-in-use' => 'This username is already taken.',
      'user-not-found' ||
      'wrong-password' ||
      'invalid-credential' =>
        'Incorrect username or password.',
      'weak-password' => 'Password must be at least 8 characters.',
      'too-many-requests' => 'Too many attempts. Try again later.',
      'quota-exceeded' => 'Service busy. Try again shortly.',
      'network-request-failed' => 'No internet connection.',
      'user-disabled' => 'This account has been deactivated.',
      _ => 'Something went wrong ($code). Please try again.',
    };
