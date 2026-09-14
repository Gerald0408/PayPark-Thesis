import 'package:cloud_firestore/cloud_firestore.dart';

/// A deactivated collector account sitting in the trash bin —
/// trashed_collectors/{uid}, the same doc that used to live at
/// collectors/{uid} before [YosRepository.deactivateCollector] moved it,
/// plus who removed it and when. Firestore doc ID is still the Firebase
/// Auth uid, so [YosRepository.restoreCollector] can recreate the original
/// collectors/{uid} doc under the same ID.
class TrashedCollector {
  TrashedCollector({
    required this.uid,
    required this.name,
    required this.username,
    required this.isAdmin,
    required this.createdAt,
    required this.deactivatedAt,
    this.phone,
    this.birthday,
    this.deactivatedBy,
  });

  final String uid;
  final String name;
  final String username;
  final bool isAdmin;
  final DateTime createdAt;
  final DateTime deactivatedAt;
  final String? phone;
  final DateTime? birthday;
  final String? deactivatedBy;

  /// Same `is`-checked-not-`as`-cast defensiveness as [Collector.fromDoc]
  /// — a stray bad write here shouldn't crash the trash bin's live stream.
  factory TrashedCollector.fromDoc(DocumentSnapshot doc) {
    final raw = doc.data();
    final d = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
    final name = d['name'];
    final username = d['username'];
    final createdAt = d['created_at'];
    final deactivatedAt = d['deactivated_at'];
    final phone = d['phone'];
    final birthday = d['birthday'];
    final deactivatedBy = d['deactivated_by'];
    return TrashedCollector(
      uid: doc.id,
      name: name is String ? name : '',
      username: username is String ? username : '',
      isAdmin: d['is_admin'] == true,
      createdAt: createdAt is Timestamp ? createdAt.toDate() : DateTime.now(),
      deactivatedAt:
          deactivatedAt is Timestamp ? deactivatedAt.toDate() : DateTime.now(),
      phone: phone is String ? phone : null,
      birthday: birthday is Timestamp ? birthday.toDate() : null,
      deactivatedBy: deactivatedBy is String ? deactivatedBy : null,
    );
  }
}
