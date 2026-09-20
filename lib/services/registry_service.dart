import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import 'document_pdf.dart';
import 'firestore_service.dart';
import 'points_settings_service.dart';
import 'vehicle_document_cache.dart';
import 'vehicle_document_storage.dart';

/// Vehicle registry: persistent database of driver + plate + vehicle type
/// + default zone. Uses Firestore's offline cache like everything else, so
/// registration and lookup both work without a network.
class VehicleRegistry {
  VehicleRegistry._();
  static final VehicleRegistry instance = VehicleRegistry._();

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('registered_vehicles');

  /// Plate keys with a [backfillPhotoSync] currently in flight — guards
  /// against two overlapping calls for the same vehicle (e.g. the
  /// Registry list's sweep re-firing because the screen was reopened
  /// before the previous sweep finished, or that sweep racing
  /// VehicleDetailScreen's own sync-on-open for the same vehicle).
  /// Without this, two uploads to the same Storage destination can race
  /// each other and get cancelled mid-transfer by the Storage SDK
  /// (surfaces as "StorageException: Object does not exist at location" /
  /// "The server has terminated the upload session") — a transient
  /// failure, not data loss, but one this avoids entirely by simply never
  /// starting a second sync for a vehicle that's already mid-sync.
  final Set<String> _syncingPlates = {};

  /// Register (or update) a vehicle by plate. Plate is the primary key —
  /// re-registering the same plate updates the existing record.
  ///
  /// [driverLicensePhotoUrl]/[orCrPhotoUrl] should be whatever this vehicle
  /// already had synced (null if never synced, or never captured). A path
  /// with no matching URL is treated as a fresh, not-yet-uploaded capture
  /// and gets uploaded to Firebase Storage here — passing the existing URL
  /// back in on every edit is what stops an unchanged photo from being
  /// re-uploaded (as a new object, with a new timestamped name) on every
  /// save. The upload itself is best-effort: offline or otherwise failed,
  /// this device's local path still gets saved and the photo simply won't
  /// be visible from other devices until a later save syncs it.
  Future<RegisteredVehicle> register({
    required String plateNumber,
    required String driverName,
    required String vehicleType,
    required String defaultZoneId,
    String? driverLicensePhotoPath,
    String? orCrPhotoPath,
    String? driverLicensePhotoUrl,
    String? orCrPhotoUrl,
    String? rfidTag,
  }) async {
    final id = RegisteredVehicle.normalize(plateNumber);

    // Preserves the vehicle's original registration date across an edit —
    // this used to be DateTime.now() unconditionally, which meant simply
    // re-saving an existing vehicle (retaking a document photo, changing
    // its zone, anything) silently bumped "registered [date]" to today.
    final existingDoc = await _col.doc(id).get();
    final registeredAt = existingDoc.exists
        ? RegisteredVehicle.fromDoc(existingDoc).registeredAt
        : DateTime.now();

    if (driverLicensePhotoPath != null && driverLicensePhotoUrl == null) {
      driverLicensePhotoUrl = await VehicleDocumentStorage.instance.upload(
          plateKey: id, docType: 'license', localKey: driverLicensePhotoPath);
    }
    if (orCrPhotoPath != null && orCrPhotoUrl == null) {
      orCrPhotoUrl = await VehicleDocumentStorage.instance.upload(
          plateKey: id, docType: 'or_cr', localKey: orCrPhotoPath);
    }

    final combined = await _buildCombinedDocument(
      plateKey: id,
      driverLicensePhotoPath: driverLicensePhotoPath,
      driverLicensePhotoUrl: driverLicensePhotoUrl,
      orCrPhotoPath: orCrPhotoPath,
      orCrPhotoUrl: orCrPhotoUrl,
    );

    final v = RegisteredVehicle(
      plateNumber: plateNumber.trim().toUpperCase(),
      driverName: driverName.trim(),
      vehicleType: vehicleType,
      defaultZoneId: defaultZoneId,
      registeredAt: registeredAt,
      driverLicensePhotoPath: driverLicensePhotoPath,
      orCrPhotoPath: orCrPhotoPath,
      driverLicensePhotoUrl: driverLicensePhotoUrl,
      orCrPhotoUrl: orCrPhotoUrl,
      documentsPath: combined?.path,
      documentsUrl: combined?.url,
      rfidTag: (rfidTag == null || rfidTag.trim().isEmpty)
          ? null
          : rfidTag.trim().toUpperCase(),
    );
    // Deterministic doc ID from normalized plate → registering the same
    // plate twice updates rather than duplicates.
    await _col.doc(id).set(v.toMap(), SetOptions(merge: true));
    return v;
  }

  /// Rebuilds the single combined PDF (driver's license then OR/CR — see
  /// DocumentPdf) from whichever raw document images actually exist right
  /// now, fetching each from its local path if this device has it, else
  /// downloading it from its own Storage URL — so retaking just *one*
  /// document still produces a correct combined file even when the other
  /// document's local file only ever existed on a different device. Null
  /// when neither document is available at all (nothing to combine), or
  /// if building/saving the PDF itself fails — best-effort, like the raw
  /// uploads above: this never blocks the rest of the save.
  Future<({String path, String? url})?> _buildCombinedDocument({
    required String plateKey,
    String? driverLicensePhotoPath,
    String? driverLicensePhotoUrl,
    String? orCrPhotoPath,
    String? orCrPhotoUrl,
  }) async {
    final licenseBytes = await VehicleDocumentStorage.instance
        .fetchBytes(path: driverLicensePhotoPath, url: driverLicensePhotoUrl);
    final orCrBytes = await VehicleDocumentStorage.instance
        .fetchBytes(path: orCrPhotoPath, url: orCrPhotoUrl);
    if (licenseBytes == null && orCrBytes == null) return null;

    try {
      final pdfBytes =
          await DocumentPdf.fromJpegImages([licenseBytes, orCrBytes]);
      final key = '${plateKey}_documents.pdf';
      await VehicleDocumentCache.instance.write(key, pdfBytes);
      final url = await VehicleDocumentStorage.instance
          .upload(plateKey: plateKey, docType: 'combined', localKey: key);
      return (path: key, url: url);
    } catch (e) {
      debugPrint('_buildCombinedDocument($plateKey) failed: $e');
      return null;
    }
  }

  /// Best-effort, silent backfill for a vehicle that predates cross-device
  /// photo sync: such a vehicle only ever got a local file path saved,
  /// never a Storage URL, which is meaningless on any device other than
  /// the one that originally captured it (see VehicleDocumentStorage's own
  /// doc comment). If *this* device happens to be that original device —
  /// the local file still exists here — this uploads it and merges the
  /// resulting URL in, the same as [register] would on a manual re-save,
  /// so the photo becomes visible from every device from now on without
  /// the collector needing to know to reopen and re-save it. A no-op for
  /// a vehicle that's already synced, was never captured, or whose local
  /// file isn't on this device — nothing usable to upload in that case.
  Future<void> backfillPhotoSync(RegisteredVehicle v) async {
    final key = RegisteredVehicle.normalize(v.plateNumber);
    if (key.isEmpty) return;
    if (!_syncingPlates.add(key)) return;
    try {
      final update = <String, dynamic>{};

      var licenseUrl = v.driverLicensePhotoUrl;
      if (v.driverLicensePhotoPath != null && licenseUrl == null) {
        licenseUrl = await VehicleDocumentStorage.instance.upload(
            plateKey: key,
            docType: 'license',
            localKey: v.driverLicensePhotoPath!);
        if (licenseUrl != null) {
          update['driver_license_photo_url'] = licenseUrl;
        }
      }
      var orCrUrl = v.orCrPhotoUrl;
      if (v.orCrPhotoPath != null && orCrUrl == null) {
        orCrUrl = await VehicleDocumentStorage.instance.upload(
            plateKey: key, docType: 'or_cr', localKey: v.orCrPhotoPath!);
        if (orCrUrl != null) update['or_cr_photo_url'] = orCrUrl;
      }
      // Also backfills a vehicle that predates the combined-PDF feature
      // entirely — it may already have both raw URLs synced (so the
      // checks above are no-ops) but never got a documents_path/url
      // written.
      if (v.documentsPath == null && v.documentsUrl == null) {
        final combined = await _buildCombinedDocument(
          plateKey: key,
          driverLicensePhotoPath: v.driverLicensePhotoPath,
          driverLicensePhotoUrl: licenseUrl,
          orCrPhotoPath: v.orCrPhotoPath,
          orCrPhotoUrl: orCrUrl,
        );
        if (combined != null) {
          update['documents_path'] = combined.path;
          if (combined.url != null) update['documents_url'] = combined.url;
        }
      }
      if (update.isEmpty) return;
      await _col.doc(key).set(update, SetOptions(merge: true));
    } finally {
      _syncingPlates.remove(key);
    }
  }

  /// True when [v] has a raw document (or the combined PDF) captured
  /// locally but never synced to Firebase Storage — meaning it's only
  /// ever visible on whichever device originally captured it. See
  /// [backfillPhotoSync].
  bool needsPhotoSync(RegisteredVehicle v) {
    final hasAnyDoc = v.driverLicensePhotoPath != null ||
        v.driverLicensePhotoUrl != null ||
        v.orCrPhotoPath != null ||
        v.orCrPhotoUrl != null;
    return (v.driverLicensePhotoPath != null &&
            v.driverLicensePhotoUrl == null) ||
        (v.orCrPhotoPath != null && v.orCrPhotoUrl == null) ||
        (hasAnyDoc && v.documentsPath == null && v.documentsUrl == null);
  }

  /// Sweeps every vehicle in [vehicles] that [needsPhotoSync] and retries
  /// its upload — called once whenever the registry list loads (see
  /// RegistryScreen), which is visited far more often than any one
  /// vehicle's own detail screen, so a photo that failed to upload at
  /// capture time (poor signal in the field is common) gets far more
  /// chances to actually sync instead of staying local-only until someone
  /// happens to reopen that exact vehicle on that exact device. Runs
  /// sequentially, one vehicle at a time, rather than all at once, so a
  /// device with many pending vehicles doesn't fire a burst of concurrent
  /// uploads over a possibly weak connection. Best-effort throughout —
  /// a vehicle whose local file isn't on this device, or whose upload
  /// fails again, is simply left for the next sweep.
  Future<void> backfillAllIfNeeded(List<RegisteredVehicle> vehicles) async {
    for (final v in vehicles) {
      if (!needsPhotoSync(v)) continue;
      try {
        await backfillPhotoSync(v);
      } catch (e) {
        debugPrint('backfillAllIfNeeded: ${v.plateNumber} failed: $e');
      }
    }
  }

  /// Look up a vehicle by plate — offline-safe (checks local cache first).
  Future<RegisteredVehicle?> lookup(String plate) async {
    final key = RegisteredVehicle.normalize(plate);
    if (key.isEmpty) return null;
    final doc = await _col.doc(key).get();
    if (!doc.exists) return null;
    return RegisteredVehicle.fromDoc(doc);
  }

  /// Look up a vehicle by its RFID tag ID instead of plate — used by the
  /// points views/redemption flow, and by RfidPointsScreen's scan handler
  /// to resolve a USB reader's scan straight to a vehicle. When a driver
  /// has more than one vehicle type enrolled under the same card (see
  /// [lookupAllByRfid]), this just returns whichever one Firestore hands
  /// back first — fine for redemption/points, which settle by plate
  /// regardless of which of a driver's vehicles this returns, but callers
  /// that need every vehicle sharing the tag (the scan-time vehicle-type
  /// picker) should use [lookupAllByRfid] instead.
  Future<RegisteredVehicle?> lookupByRfid(String tag) async {
    final key = RegisteredVehicle.normalize(tag);
    if (key.isEmpty) return null;
    final snap =
        await _col.where('rfid_tag_key', isEqualTo: key).limit(1).get();
    if (snap.docs.isEmpty) return null;
    return RegisteredVehicle.fromDoc(snap.docs.first);
  }

  /// Every vehicle enrolled under [tag] — a driver can register more than
  /// one vehicle type (different plate, own OR/CR) under the same RFID
  /// card, so the scan-time picker (see pickVehicleForRfidTag) needs the
  /// full set, not just one match, to know which of the 4 vehicle types
  /// already have their own details saved versus which still need them
  /// added. Each entry is its own separate plate-keyed document (see
  /// [register]) — adding a new type never touches another type's
  /// document, so nothing already registered under this tag is ever
  /// overwritten by adding another.
  Future<List<RegisteredVehicle>> lookupAllByRfid(String tag) async {
    final key = RegisteredVehicle.normalize(tag);
    if (key.isEmpty) return const [];
    final snap = await _col.where('rfid_tag_key', isEqualTo: key).get();
    return snap.docs.map(RegisteredVehicle.fromDoc).toList();
  }

  /// Increment entry counter + last-seen timestamp when a registered
  /// vehicle is logged, and settle its RFID points balance for the
  /// transaction that just happened: [fee] is what was actually charged
  /// (after any redemption already applied — see the receipt drawer in
  /// vehicle_entry_screen.dart), [redeemedPoints] is how many points that
  /// redemption spent (flat per tier — see redemptionPointsCost). A
  /// redeemed transaction is pure spend: it earns no new points on top,
  /// so redeeming never nets back part of what it just cost. Points only
  /// move for vehicles enrolled with an RFID tag (see
  /// RegisteredVehicle.rfidTag) — everyone else keeps today's
  /// entry-count-only behavior. Best-effort, single merge write — never
  /// blocks the entry write, and (like every other offline-first write in
  /// this app) two devices redeeming the same balance while both offline
  /// could over-redeem before they sync.
  ///
  /// Every points move also lands in the permanent audit trail (see
  /// firestore.rules' audit_logs — append-only, never editable or
  /// deletable) as its own ledger-style entry: earning and redeeming are
  /// logged separately, each with the exact previous/new balance either
  /// side of it, even though both apply in this one merge write —
  /// exactly what a compliance record needs, not just "balance changed
  /// by some net amount."
  Future<void> touch(
    String plate, {
    required double fee,
    double redeemedPoints = 0,
  }) async {
    final key = RegisteredVehicle.normalize(plate);
    if (key.isEmpty) return;
    final update = <String, dynamic>{
      'entry_count': FieldValue.increment(1),
      'last_seen': Timestamp.fromDate(DateTime.now()),
    };
    final doc = await _col.doc(key).get();
    final enrolled = (doc.data()?['rfid_tag'] as String?) != null;
    if (enrolled) {
      final earned = redeemedPoints > 0
          ? 0.0
          : PointsSettingsService.instance.pointsForFee(fee);
      update['points'] = FieldValue.increment(earned - redeemedPoints);

      final before = (doc.data()?['points'] as num?)?.toDouble() ?? 0;
      var running = before;
      if (earned > 0) {
        final afterEarn = running + earned;
        YosRepository.instance.logAudit(
          AuditAction.pointsEarned,
          '$plate earned ${formatPoints(earned)} pts (fee ₱${fee.toStringAsFixed(0)})',
          previousValue: running,
          newValue: afterEarn,
        );
        running = afterEarn;
      }
      if (redeemedPoints > 0) {
        final afterRedeem = running - redeemedPoints;
        YosRepository.instance.logAudit(
          AuditAction.pointsRedeemed,
          '$plate redeemed ${formatPoints(redeemedPoints)} pts',
          previousValue: running,
          newValue: afterRedeem,
        );
      }
    }
    _col.doc(key).set(update, SetOptions(merge: true));
  }

  /// Live stream of all registered vehicles, newest first.
  Stream<List<RegisteredVehicle>> all() => _col
      .orderBy('registered_at', descending: true)
      .snapshots(includeMetadataChanges: true)
      .map((s) => s.docs.map(RegisteredVehicle.fromDoc).toList());

  Future<void> delete(String plate) async {
    final key = RegisteredVehicle.normalize(plate);
    if (key.isEmpty) return;
    // Best-effort: clear any attached document photos (local file and
    // synced Storage copy) before dropping the record, so deleting a
    // vehicle doesn't leave orphaned scans behind. Never blocks the
    // actual delete.
    try {
      final doc = await _col.doc(key).get();
      if (doc.exists) {
        final v = RegisteredVehicle.fromDoc(doc);
        for (final path in [
          v.driverLicensePhotoPath,
          v.orCrPhotoPath,
          v.documentsPath
        ]) {
          if (path == null) continue;
          await VehicleDocumentCache.instance.delete(path);
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
        for (final url in [
          v.driverLicensePhotoUrl,
          v.orCrPhotoUrl,
          v.documentsUrl
        ]) {
          if (url == null) continue;
          await VehicleDocumentStorage.instance.deleteByUrl(url);
        }
      }
    } catch (_) {}
    await _col.doc(key).delete();
  }
}
