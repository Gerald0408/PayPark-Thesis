import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import 'firestore_service.dart';
import 'points_settings_service.dart';

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
  Future<RegisteredVehicle> register({
    required String plateNumber,
    required String driverName,
    required String vehicleType,
    required String defaultZoneId,
    String? driverLicensePhotoPath,
    String? orCrPhotoPath,
    String? rfidTag,
  }) async {
    final v = RegisteredVehicle(
      plateNumber: plateNumber.trim().toUpperCase(),
      driverName: driverName.trim(),
      vehicleType: vehicleType,
      defaultZoneId: defaultZoneId,
      registeredAt: DateTime.now(),
      driverLicensePhotoPath: driverLicensePhotoPath,
      orCrPhotoPath: orCrPhotoPath,
      rfidTag: (rfidTag == null || rfidTag.trim().isEmpty)
          ? null
          : rfidTag.trim().toUpperCase(),
    );
    // Deterministic doc ID from normalized plate → registering the same
    // plate twice updates rather than duplicates.
    final id = RegisteredVehicle.normalize(v.plateNumber);
    await _col.doc(id).set(v.toMap(), SetOptions(merge: true));
    return v;
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
  /// redemption spent. Points only move for vehicles enrolled with an
  /// RFID tag (see RegisteredVehicle.rfidTag) — everyone else keeps
  /// today's entry-count-only behavior. Best-effort, single merge write —
  /// never blocks the entry write, and (like every other offline-first
  /// write in this app) two devices redeeming the same balance while both
  /// offline could over-redeem before they sync.
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
      final earned = PointsSettingsService.instance.pointsForFee(fee);
      update['points'] = FieldValue.increment(earned - redeemedPoints);

      final before = (doc.data()?['points'] as num?)?.toDouble() ?? 0;
      final afterEarn = before + earned;
      YosRepository.instance.logAudit(
        AuditAction.pointsEarned,
        '$plate earned ${formatPoints(earned)} pts (fee ₱${fee.toStringAsFixed(0)})',
        previousValue: before,
        newValue: afterEarn,
      );
      if (redeemedPoints > 0) {
        final afterRedeem = afterEarn - redeemedPoints;
        YosRepository.instance.logAudit(
          AuditAction.pointsRedeemed,
          '$plate redeemed ${formatPoints(redeemedPoints)} pts',
          previousValue: afterEarn,
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
    // Best-effort: clear any attached document photos off disk before
    // dropping the record, so deleting a vehicle doesn't leave orphaned
    // scans behind. Never blocks the actual delete.
    try {
      final doc = await _col.doc(key).get();
      if (doc.exists) {
        final v = RegisteredVehicle.fromDoc(doc);
        for (final path in [v.driverLicensePhotoPath, v.orCrPhotoPath]) {
          if (path == null) continue;
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
      }
    } catch (_) {}
    await _col.doc(key).delete();
  }
}
