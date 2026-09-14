import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

/// Syncs captured vehicle document photos (driver's license, OR/CR) to
/// Firebase Storage so any device — not just the one that captured them —
/// can display them. Without this, RegisteredVehicle's photo fields only
/// ever held a local file path, which is meaningless on any device other
/// than the one that captured it: opening the same vehicle from a
/// different collector's or admin's phone showed a broken-image icon.
/// The local path stays the fast, no-network same-device path (see
/// DocPhotoView); this is what makes every *other* device able to show
/// the same photo at all.
class VehicleDocumentStorage {
  VehicleDocumentStorage._();
  static final VehicleDocumentStorage instance = VehicleDocumentStorage._();

  Reference get _root => FirebaseStorage.instance.ref('vehicle_documents');

  /// Uploads [localPath] under `vehicle_documents/{plateKey}/{docType}_{ts}`
  /// and returns its download URL, or null if the upload fails (offline,
  /// permission, the local file having already been deleted, etc.) —
  /// callers keep the vehicle's local-only path in that case, same
  /// behavior as before Storage sync existed.
  Future<String?> upload({
    required String plateKey,
    required String docType,
    required String localPath,
  }) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) return null;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = _root.child(plateKey).child('${docType}_$ts.jpg');
      await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
      return await ref.getDownloadURL();
    } catch (e) {
      return null;
    }
  }

  /// Best-effort delete by download URL — never throws; a failed cleanup
  /// just leaves an orphaned Storage object behind, the same tradeoff
  /// VehicleRegistry.delete already makes for local files.
  Future<void> deleteByUrl(String url) async {
    try {
      await FirebaseStorage.instance.refFromURL(url).delete();
    } catch (_) {}
  }
}
