import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import 'firestore_service.dart';
import 'points_settings_service.dart';
import 'vehicle_document_storage.dart';

/// Vehicle registry: persistent database of driver + plate + vehicle type
/// + default zone. Uses Firestore's offline cache like everything else, so
/// registration and lookup both work without a network.
class VehicleRegistry {
  VehicleRegistry._();
  static final VehicleRegistry instance = VehicleRegistry._();

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('registered_vehicles');

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

    if (driverLicensePhotoPath != null && driverLicensePhotoUrl == null) {
      driverLicensePhotoUrl = await VehicleDocumentStorage.instance.upload(
          plateKey: id, docType: 'license', localPath: driverLicensePhotoPath);
    }
    if (orCrPhotoPath != null && orCrPhotoUrl == null) {
      orCrPhotoUrl = await VehicleDocumentStorage.instance.upload(
          plateKey: id, docType: 'or_cr', localPath: orCrPhotoPath);
    }

    final v = RegisteredVehicle(
      plateNumber: plateNumber.trim().toUpperCase(),
      driverName: driverName.trim(),
      vehicleType: vehicleType,
      defaultZoneId: defaultZoneId,
      registeredAt: DateTime.now(),
      driverLicensePhotoPath: driverLicensePhotoPath,
      orCrPhotoPath: orCrPhotoPath,
      driverLicensePhotoUrl: driverLicensePhotoUrl,
      orCrPhotoUrl: orCrPhotoUrl,
      rfidTag: (rfidTag == null || rfidTag.trim().isEmpty)
          ? null
          : rfidTag.trim().toUpperCase(),
    );
    // Deterministic doc ID from normalized plate → registering the same
    // plate twice updates rather than duplicates.
    await _col.doc(id).set(v.toMap(), SetOptions(merge: true));
    return v;
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
    final update = <String, dynamic>{};

    if (v.driverLicensePhotoPath != null && v.driverLicensePhotoUrl == null) {
      final url = await VehicleDocumentStorage.instance.upload(
          plateKey: key,
          docType: 'license',
          localPath: v.driverLicensePhotoPath!);
      if (url != null) update['driver_license_photo_url'] = url;
    }
    if (v.orCrPhotoPath != null && v.orCrPhotoUrl == null) {
      final url = await VehicleDocumentStorage.instance.upload(
          plateKey: key, docType: 'or_cr', localPath: v.orCrPhotoPath!);
      if (url != null) update['or_cr_photo_url'] = url;
    }
    if (update.isEmpty) return;
    await _col.doc(key).set(update, SetOptions(merge: true));
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
  /// to resolve a USB reader's scan straight to a vehicle.
  Future<RegisteredVehicle?> lookupByRfid(String tag) async {
    final key = RegisteredVehicle.normalize(tag);
    if (key.isEmpty) return null;
    final snap =
        await _col.where('rfid_tag_key', isEqualTo: key).limit(1).get();
    if (snap.docs.isEmpty) return null;
    return RegisteredVehicle.fromDoc(snap.docs.first);
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
        for (final path in [v.driverLicensePhotoPath, v.orCrPhotoPath]) {
          if (path == null) continue;
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
        for (final url in [v.driverLicensePhotoUrl, v.orCrPhotoUrl]) {
          if (url == null) continue;
          await VehicleDocumentStorage.instance.deleteByUrl(url);
        }
      }
    } catch (_) {}
    await _col.doc(key).delete();
  }
}
