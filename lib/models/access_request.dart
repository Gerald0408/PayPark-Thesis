import 'package:cloud_firestore/cloud_firestore.dart';

/// A "help me back in" ping from a locked-out collector — see
/// YosRepository.requestAccessReset. Deliberately weak identity (just a
/// typed name, no verification): there's no phone/OTP path left to
/// self-verify who someone is once accounts aren't tied to a phone number,
/// so this is a notification for the admin to act on using real-world
/// knowledge of who their collectors are, not an authenticated claim.
class AccessRequest {
  AccessRequest({
    required this.id,
    required this.name,
    required this.requestedAt,
    this.status = 'pending',
    this.newUsername,
  });

  final String id;
  final String name;
  final DateTime requestedAt;
  final String status;

  /// Set once an admin actually grants the reset (see
  /// YosRepository.resolveAccessRequest) — the new username they chose
  /// for the collector's brand-new account. Null while still pending.
  /// Never carries the passcode itself: that's told to the collector
  /// out-of-band by the admin, same as it always was — this field only
  /// lets the waiting collector's own screen (see AccessRequestScreen)
  /// know *which* account to type that passcode into once it's ready.
  final String? newUsername;

  factory AccessRequest.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return AccessRequest(
      id: doc.id,
      name: d['name'] ?? '',
      requestedAt: (d['requested_at'] as Timestamp?)?.toDate() ?? DateTime.now(),
      status: d['status'] is String ? d['status'] as String : 'pending',
      newUsername: d['new_username'] is String ? d['new_username'] as String : null,
    );
  }
}
