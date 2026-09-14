import 'package:cloud_firestore/cloud_firestore.dart';

/// A single vehicle entry / collection transaction.
class ParkingTransaction {
  ParkingTransaction({
    required this.trackingId,
    required this.driverName,
    required this.plateNumber,
    required this.vehicleType,
    required this.fee,
    required this.zoneId,
    required this.timestamp,
    this.printed = false,
    this.docId,
    this.pendingSync = false,
    this.discount = 0,
  });

  final String trackingId;
  final String driverName;
  final String plateNumber;
  final String vehicleType;
  final double fee;
  final String zoneId;
  final DateTime timestamp;
  final bool printed;
  final String? docId;

  /// True while the write only exists in the local Firestore cache.
  final bool pendingSync;

  /// Pesos knocked off this transaction's fee via an RFID points
  /// redemption (see ReceiptPreviewDrawer._redeemedValue) — 0 for the
  /// common case of no redemption. [fee] is always the already-discounted
  /// amount actually charged; this is what makes that visible after the
  /// fact instead of a past transaction just looking like a plain, lower
  /// fee with no record a discount was ever applied.
  final double discount;

  ParkingTransaction copyWith({bool? printed, double? fee, double? discount}) =>
      ParkingTransaction(
        trackingId: trackingId,
        driverName: driverName,
        plateNumber: plateNumber,
        vehicleType: vehicleType,
        fee: fee ?? this.fee,
        zoneId: zoneId,
        timestamp: timestamp,
        printed: printed ?? this.printed,
        docId: docId,
        pendingSync: pendingSync,
        discount: discount ?? this.discount,
      );

  Map<String, dynamic> toMap() => {
        'tracking_id': trackingId,
        'driver_name': driverName,
        'plate_number': plateNumber,
        'vehicle_type': vehicleType,
        'fee': fee,
        'zone_id': zoneId,
        'timestamp': Timestamp.fromDate(timestamp),
        'printed': printed,
        if (discount > 0) 'discount': discount,
      };

  factory ParkingTransaction.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return ParkingTransaction(
      docId: doc.id,
      trackingId: d['tracking_id'] ?? '',
      driverName: d['driver_name'] ?? '',
      plateNumber: d['plate_number'] ?? '',
      vehicleType: d['vehicle_type'] ?? 'Sedan',
      fee: (d['fee'] as num?)?.toDouble() ?? 0,
      zoneId: d['zone_id'] ?? '',
      timestamp: (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      printed: d['printed'] ?? false,
      pendingSync: doc.metadata.hasPendingWrites,
      discount: (d['discount'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Immutable security audit event — append-only per firestore.rules
/// (collectors/{uid}-style update/delete is disallowed entirely on
/// audit_logs), so once written this is the permanent record of what
/// happened. [previousValue]/[newValue] capture a before/after numeric
/// change (a points balance, a fee, an earn rate) for actions that have
/// one; null for actions that don't (a login has no "balance").
class AuditLog {
  AuditLog({
    required this.logId,
    required this.actorId,
    required this.actionType,
    required this.description,
    required this.timestamp,
    this.actorName,
    this.pendingSync = false,
    this.previousValue,
    this.newValue,
  });

  final String logId;
  final String actorId;
  // Snapshotted at write time (see YosRepository.logAudit), not resolved
  // live from collectors/{actorId} — a name change or account removal
  // later shouldn't rewrite what the audit trail already says happened.
  // Null for logs written before this field existed — AuditScreen's own
  // _actorDisplay is what falls back to a live uid lookup (or the raw
  // actorId) for those.
  final String? actorName;
  final String actionType;
  final String description;
  final DateTime timestamp;
  final bool pendingSync;
  final double? previousValue;
  final double? newValue;

  Map<String, dynamic> toMap() => {
        'log_id': logId,
        'actor_id': actorId,
        if (actorName != null) 'actor_name': actorName,
        'action_type': actionType,
        'description': description,
        'timestamp': Timestamp.fromDate(timestamp),
        if (previousValue != null) 'previous_value': previousValue,
        if (newValue != null) 'new_value': newValue,
      };

  factory AuditLog.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final actorName = d['actor_name'];
    return AuditLog(
      logId: d['log_id'] ?? doc.id,
      actorId: d['actor_id'] ?? '',
      actorName: actorName is String && actorName.isNotEmpty ? actorName : null,
      actionType: d['action_type'] ?? '',
      description: d['description'] ?? '',
      timestamp: (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      pendingSync: doc.metadata.hasPendingWrites,
      previousValue: (d['previous_value'] as num?)?.toDouble(),
      newValue: (d['new_value'] as num?)?.toDouble(),
    );
  }
}

/// Audit action taxonomy.
class AuditAction {
  static const login = 'LOGIN';
  static const logout = 'LOGOUT';
  static const loginFailed = 'LOGIN_FAILED';
  static const register = 'REGISTER';
  static const faceEnroll = 'FACE_ENROLL';
  static const faceIdRemoved = 'FACE_ID_REMOVED';
  static const faceLoginSuccess = 'FACE_LOGIN_SUCCESS';
  static const faceLoginFailed = 'FACE_LOGIN_FAILED';
  static const newEntry = 'NEW_ENTRY';
  static const search = 'SEARCH';
  static const syncOnline = 'SYNC_ONLINE';
  static const syncOffline = 'SYNC_OFFLINE';
  static const backup = 'LOCAL_BACKUP';
  static const printReceipt = 'PRINT_RECEIPT';
  static const feeUpdated = 'FEE_UPDATED';
  static const deactivateCollector = 'DEACTIVATE_COLLECTOR';
  static const restoreCollector = 'RESTORE_COLLECTOR';
  static const permanentlyDeleteCollector = 'PERMANENTLY_DELETE_COLLECTOR';
  static const claimAdmin = 'CLAIM_ADMIN';
  static const adminPromoted = 'ADMIN_PROMOTED';
  static const adminDemoted = 'ADMIN_DEMOTED';
  static const passwordReset = 'PASSWORD_RESET';
  static const accessRequestResolved = 'ACCESS_REQUEST_RESOLVED';
  static const pointsRateUpdated = 'POINTS_RATE_UPDATED';
  static const pointsEarned = 'POINTS_EARNED';
  static const pointsRedeemed = 'POINTS_REDEEMED';
}
