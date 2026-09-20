import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'vehicle_document_cache.dart';

/// Syncs captured vehicle document photos (driver's license, OR/CR) to
/// Firebase Storage so any device — not just the one that captured them —
/// can display them. Without this, RegisteredVehicle's photo fields only
/// ever held a local key, which is meaningless on any device other than
/// the one that captured it: opening the same vehicle from a different
/// collector's or admin's phone showed a broken-image icon. The local
/// copy (see VehicleDocumentCache) stays the fast, no-network same-device
/// path (see DocPhotoView); this is what makes every *other* device able
/// to show the same photo at all.
class VehicleDocumentStorage {
  VehicleDocumentStorage._();
  static final VehicleDocumentStorage instance = VehicleDocumentStorage._();

  Reference get _root => FirebaseStorage.instance.ref('vehicle_documents');

  /// Uploads [localKey]'s cached bytes under
  /// `vehicle_documents/{plateKey}/{docType}_{ts}` and returns its
  /// download URL, or null if the upload fails (offline, permission, the
  /// local copy having already been evicted, etc.) — callers keep the
  /// vehicle's local-only copy in that case, same behavior as before
  /// Storage sync existed.
  ///
  /// [localKey] is looked up in [VehicleDocumentCache] first (every
  /// capture since that cache shipped), falling back to reading it as a
  /// plain filesystem path for a legacy capture from before Hive existed.
  ///
  /// Extension/content-type follow [localKey] itself rather than being
  /// hardcoded — captured documents are one-page PDFs now (see
  /// DocumentPdf), but this stays format-agnostic so it still works for
  /// any older local-only capture that's still a plain JPEG.
  Future<String?> upload({
    required String plateKey,
    required String docType,
    required String localKey,
  }) async {
    try {
      final bytes = VehicleDocumentCache.instance.read(localKey) ??
          await _readLegacyFile(localKey);
      if (bytes == null) return null;
      final isPdf = localKey.toLowerCase().endsWith('.pdf');
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ext = isPdf ? 'pdf' : 'jpg';
      final contentType = isPdf ? 'application/pdf' : 'image/jpeg';
      final ref = _root.child(plateKey).child('${docType}_$ts.$ext');
      await ref.putData(bytes, SettableMetadata(contentType: contentType));
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('VehicleDocumentStorage.upload($plateKey/$docType) failed: $e');
      return null;
    }
  }

  Future<Uint8List?> _readLegacyFile(String path) async {
    final file = File(path);
    return await file.exists() ? file.readAsBytes() : null;
  }

  /// Best-effort delete by download URL — never throws; a failed cleanup
  /// just leaves an orphaned Storage object behind, the same tradeoff
  /// VehicleRegistry.delete already makes for local files.
  Future<void> deleteByUrl(String url) async {
    try {
      await FirebaseStorage.instance.refFromURL(url).delete();
    } catch (e) {
      debugPrint('VehicleDocumentStorage.deleteByUrl failed: $e');
    }
  }

  /// Reads a document's actual bytes from whichever source is available —
  /// the local cache first (fast, no network; a legacy filesystem-path
  /// [path] falls back to a plain file read), then downloading [url] — or
  /// null if nothing has it. Used to gather the source images for a fresh
  /// combined PDF (see DocumentPdf) even when this device only has one of
  /// the two documents' local copies on hand.
  Future<Uint8List?> fetchBytes({String? path, String? url}) async {
    if (path != null) {
      final cached = VehicleDocumentCache.instance.read(path);
      if (cached != null) return cached;
      final legacy = await _readLegacyFile(path);
      if (legacy != null) return legacy;
    }
    if (url == null) return null;
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        final bytes = BytesBuilder();
        await for (final chunk in response) {
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('VehicleDocumentStorage.fetchBytes($url) failed: $e');
      return null;
    }
  }
}
