import 'package:cloud_firestore/cloud_firestore.dart';

/// A registered collector account, as seen from the admin's collectors
/// list. Firestore doc ID is the Firebase Auth uid.
class Collector {
  Collector({
    required this.uid,
    required this.name,
    required this.username,
    required this.isAdmin,
    required this.createdAt,
    this.phone,
    this.birthday,
    this.photoUrl,
  });

  final String uid;
  final String name;
  final String username;
  final bool isAdmin;
  final DateTime createdAt;

  // Nullable: added alongside the passwordless registration form — an
  // account registered before that change simply has neither field.
  final String? phone;
  final DateTime? birthday;

  // Null until the collector sets one from ProfileScreen (see
  // CollectorPhotoStorage) — falls back to initials everywhere this is
  // shown.
  final String? photoUrl;

  /// `is`-checked rather than `as`-cast on every field: a doc with a
  /// field of the wrong type (bad manual edit, a stale/partial write,
  /// whatever) falls back to a sane default here instead of throwing
  /// inside the live [DocumentSnapshot] stream this feeds — an error
  /// there has no [DocumentSnapshot] for the UI to show, and no way to
  /// retry, so it reads as a screen stuck loading forever instead of a
  /// visible, actionable failure.
  factory Collector.fromDoc(DocumentSnapshot doc) {
    final raw = doc.data();
    final d = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
    final name = d['name'];
    final username = d['username'];
    final createdAt = d['created_at'];
    final phone = d['phone'];
    final birthday = d['birthday'];
    final photoUrl = d['photo_url'];
    return Collector(
      uid: doc.id,
      name: name is String ? name : '',
      username: username is String ? username : '',
      isAdmin: d['is_admin'] == true,
      createdAt: createdAt is Timestamp ? createdAt.toDate() : DateTime.now(),
      phone: phone is String ? phone : null,
      birthday: birthday is Timestamp ? birthday.toDate() : null,
      photoUrl: photoUrl is String ? photoUrl : null,
    );
  }
}
