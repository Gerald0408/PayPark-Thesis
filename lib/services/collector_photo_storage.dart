import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

/// Syncs a collector's own profile photo to Firebase Storage, one file per
/// uid (each new upload overwrites the last) — same shape as
/// VehicleDocumentStorage, just keyed by uid instead of plate and with a
/// single fixed filename rather than a per-capture timestamped one, since
/// there's only ever one current profile photo.
class CollectorPhotoStorage {
  CollectorPhotoStorage._();
  static final CollectorPhotoStorage instance = CollectorPhotoStorage._();

  Reference get _root => FirebaseStorage.instance.ref('collector_photos');

  /// Uploads [localPath] under `collector_photos/{uid}/photo.jpg` and
  /// returns its download URL, or null if the upload fails (offline,
  /// permission, the picked file having already been deleted, etc.).
  Future<String?> upload({
    required String uid,
    required String localPath,
  }) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) return null;
      final ref = _root.child(uid).child('photo.jpg');
      await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
      return await ref.getDownloadURL();
    } catch (e) {
      return null;
    }
  }
}
