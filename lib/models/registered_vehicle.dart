import 'package:cloud_firestore/cloud_firestore.dart';

/// A vehicle whose details are remembered so entry can be one-tap
/// (or one-scan) later. Plate number is the identity key.
class RegisteredVehicle {
  RegisteredVehicle({
    required this.plateNumber,
    required this.driverName,
    required this.vehicleType,
    required this.defaultZoneId,
    required this.registeredAt,
    this.entryCount = 0,
    this.lastSeen,
    this.docId,
    this.driverLicensePhotoPath,
    this.orCrPhotoPath,
    this.driverLicensePhotoUrl,
    this.orCrPhotoUrl,
    this.rfidTag,
    this.points = 0.0,
  });

  final String plateNumber; // normalized, uppercase, spaces preserved
  final String driverName;
  final String vehicleType;
  final String defaultZoneId;
  final DateTime registeredAt;
  final int entryCount;
  final DateTime? lastSeen;
  final String? docId;

  /// RFID card ID — filled either by a plug-and-play USB reader (see
  /// RegisterVehicleScreen's onFieldSubmitted / RfidPointsScreen's
  /// onSubmitted, both of which just listen for the Enter keystroke a
  /// USB-HID reader sends after "typing" the tag) or typed by hand. Null
  /// means this vehicle isn't enrolled in the points program (see
  /// VehicleRegistry.touch / PointsSettingsService).
  final String? rfidTag;

  /// Loyalty points balance — only accrues for vehicles with [rfidTag]
  /// set. See VehicleRegistry.touch for how it's earned and
  /// vehicle_entry_screen.dart's receipt drawer for how it's redeemed.
  /// A double (not an int) since a session can earn a fraction of a
  /// point — see PointsSettingsService.pointsForFee.
  final double points;

  /// Local file paths — fast, no-network access on whichever device
  /// actually captured the photo, but meaningless on any other device.
  final String? driverLicensePhotoPath;
  final String? orCrPhotoPath;

  /// Firebase Storage download URLs (see VehicleDocumentStorage) — what
  /// lets a *different* device (another collector's phone, the admin's)
  /// display the same photo. Null until the local capture has actually
  /// finished uploading (best-effort — see VehicleRegistry.register), so
  /// a photo captured while offline may only have the local path above
  /// until the next successful save syncs it.
  final String? driverLicensePhotoUrl;
  final String? orCrPhotoUrl;

  /// Search key: uppercase plate with spaces stripped, for exact-match lookup.
  static String normalize(String plate) =>
      plate.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

  Map<String, dynamic> toMap() => {
        'plate_number': plateNumber,
        'plate_key': normalize(plateNumber),
        'driver_name': driverName,
        'vehicle_type': vehicleType,
        'default_zone_id': defaultZoneId,
        'registered_at': Timestamp.fromDate(registeredAt),
        'entry_count': entryCount,
        if (lastSeen != null) 'last_seen': Timestamp.fromDate(lastSeen!),
        if (driverLicensePhotoPath != null)
          'driver_license_photo_path': driverLicensePhotoPath,
        if (orCrPhotoPath != null) 'or_cr_photo_path': orCrPhotoPath,
        if (driverLicensePhotoUrl != null)
          'driver_license_photo_url': driverLicensePhotoUrl,
        if (orCrPhotoUrl != null) 'or_cr_photo_url': orCrPhotoUrl,
        if (rfidTag != null) 'rfid_tag': rfidTag,
        if (rfidTag != null) 'rfid_tag_key': normalize(rfidTag!),
        'points': points,
      };

  factory RegisteredVehicle.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return RegisteredVehicle(
      docId: doc.id,
      plateNumber: d['plate_number'] ?? '',
      driverName: d['driver_name'] ?? '',
      vehicleType: d['vehicle_type'] ?? 'Sedan',
      defaultZoneId: d['default_zone_id'] ?? '',
      registeredAt:
          (d['registered_at'] as Timestamp?)?.toDate() ?? DateTime.now(),
      entryCount: (d['entry_count'] as num?)?.toInt() ?? 0,
      lastSeen: (d['last_seen'] as Timestamp?)?.toDate(),
      driverLicensePhotoPath: d['driver_license_photo_path'] as String?,
      orCrPhotoPath: d['or_cr_photo_path'] as String?,
      driverLicensePhotoUrl: d['driver_license_photo_url'] as String?,
      orCrPhotoUrl: d['or_cr_photo_url'] as String?,
      rfidTag: d['rfid_tag'] as String?,
      points: (d['points'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
