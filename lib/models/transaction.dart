import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/names.dart';

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
    this.collectorId,
    this.collectorName,
    this.paymentMethod = PaymentMethod.cash,
    this.paymentRef,
    this.source = EntrySource.manual,
    this.rfidTagKey,
    this.timeOut,
    this.checkedOutByName,
    this.checkedOutBy,
    this.tracksCheckout = true,
    this.extraHours = 0,
    this.extraFee = 0,
    this.extraPaymentMethod,
    this.extraPaymentRef,
    this.lostTicketFee = 0,
    this.plannedHours,
    this.geoLat,
    this.geoLng,
    this.geoAccuracy,
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

  /// Who collected this — snapshotted at build time (see
  /// YosRepository.buildTransaction) so a reprint or the daily blotter
  /// still names the right collector later. Null on transactions logged
  /// before these fields existed.
  final String? collectorId;
  final String? collectorName;

  /// How the driver paid — see [PaymentMethod]. Transactions from before
  /// this field existed read back as cash, the only option back then.
  final String paymentMethod;

  /// Digital payment reference number (GCash/Maya), as read off the
  /// driver's confirmation screen — null for cash.
  final String? paymentRef;

  /// How the vehicle was identified — see [EntrySource]. Older
  /// transactions read back as manual.
  final String source;

  /// Normalized RFID tag (RegisteredVehicle.normalize) of the vehicle this
  /// was charged to, when it has a card — what lets that driver read
  /// this transaction from the driver portal (see firestore.rules).
  final String? rfidTagKey;

  bool get isDigital => paymentMethod != PaymentMethod.cash;

  /// When the vehicle left — null while it's still parked. [timestamp] is
  /// the time in. No extra charge at check-out: the fee is paid at
  /// check-in; this only records the stay.
  final DateTime? timeOut;
  final String? checkedOutByName;

  /// Uid of whoever did the time out — who took the money under
  /// pay-at-time-out. Written by the check-out itself (see
  /// YosRepository's time out), so it's read here but never in [toMap].
  final String? checkedOutBy;

  /// Who holds this visit's money: whoever timed it out (the fee is paid
  /// at time out), else whoever timed it in. Shift summaries and the
  /// blotter's By Collector totals both group on this, so they agree.
  String? get collectedById => checkedOutBy ?? collectorId;
  String? get collectedByName =>
      checkedOutBy != null ? checkedOutByName : collectorName;

  /// False for transactions logged before check-out existed — those have
  /// no time out to record and must never look "still parked".
  final bool tracksCheckout;

  bool get awaitingCheckout => tracksCheckout && timeOut == null;

  /// Overtime collected at check-out: hours started past the base hours
  /// the check-in [fee] covered (see FeeSettingsService.overtimeFor), and
  /// what they cost. 0 until checked out, and when the stay was short.
  final int extraHours;
  final double extraFee;

  /// How the overtime was paid — may differ from the check-in's
  /// [paymentMethod]. Null when there was no overtime.
  final String? extraPaymentMethod;
  final String? extraPaymentRef;

  /// Everything this visit has paid — what every total must add up.
  double get totalPaid => fee + extraFee + lostTicketFee;

  /// Charged at time out when the driver couldn't present the time-in
  /// ticket — see FeeSettingsService.lostTicketFee.
  final double lostTicketFee;

  /// Hours the driver chose to park for at TIME IN — printed on the
  /// ticket with the expected time out and an estimated fee. Only a
  /// guide: the actual fee is computed from the real time out.
  final int? plannedHours;

  /// A time-in ticket that hasn't been paid yet: under time-in/time-out
  /// billing nothing is collected until the vehicle leaves.
  bool get isUnpaidTicket => awaitingCheckout && totalPaid == 0;

  /// Where the check-in receipt was issued (see LocationService) — null
  /// when the phone had no location fix or permission.
  final double? geoLat;
  final double? geoLng;
  final double? geoAccuracy;

  /// "14.59951,120.98422", or null without a geotag.
  String? get geoShort => geoLat == null || geoLng == null
      ? null
      : '${geoLat!.toStringAsFixed(5)},${geoLng!.toStringAsFixed(5)}';

  /// Time in to time out (or to now while still parked).
  Duration get stayDuration =>
      (timeOut ?? DateTime.now()).difference(timestamp);

  ParkingTransaction copyWith({
    bool? printed,
    double? fee,
    double? discount,
    String? paymentMethod,
    String? paymentRef,
    String? rfidTagKey,
    double? geoLat,
    double? geoLng,
    double? geoAccuracy,
    DateTime? timestamp,
    DateTime? timeOut,
    String? checkedOutByName,
    int? extraHours,
    double? extraFee,
    String? extraPaymentMethod,
    String? extraPaymentRef,
    double? lostTicketFee,
    int? plannedHours,
  }) =>
      ParkingTransaction(
        trackingId: trackingId,
        driverName: driverName,
        plateNumber: plateNumber,
        vehicleType: vehicleType,
        fee: fee ?? this.fee,
        zoneId: zoneId,
        timestamp: timestamp ?? this.timestamp,
        printed: printed ?? this.printed,
        docId: docId,
        pendingSync: pendingSync,
        discount: discount ?? this.discount,
        collectorId: collectorId,
        collectorName: collectorName,
        paymentMethod: paymentMethod ?? this.paymentMethod,
        paymentRef: paymentRef ?? this.paymentRef,
        source: source,
        rfidTagKey: rfidTagKey ?? this.rfidTagKey,
        timeOut: timeOut ?? this.timeOut,
        checkedOutByName: checkedOutByName ?? this.checkedOutByName,
        checkedOutBy: checkedOutBy,
        tracksCheckout: tracksCheckout,
        extraHours: extraHours ?? this.extraHours,
        extraFee: extraFee ?? this.extraFee,
        extraPaymentMethod: extraPaymentMethod ?? this.extraPaymentMethod,
        extraPaymentRef: extraPaymentRef ?? this.extraPaymentRef,
        lostTicketFee: lostTicketFee ?? this.lostTicketFee,
        plannedHours: plannedHours ?? this.plannedHours,
        geoLat: geoLat ?? this.geoLat,
        geoLng: geoLng ?? this.geoLng,
        geoAccuracy: geoAccuracy ?? this.geoAccuracy,
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
        if (collectorId != null) 'collector_id': collectorId,
        if (collectorName != null) 'collector_name': collectorName,
        'payment_method': paymentMethod,
        if (paymentRef != null && paymentRef!.isNotEmpty)
          'payment_ref': paymentRef,
        'source': source,
        if (rfidTagKey != null) 'rfid_tag_key': rfidTagKey,
        // Always written (null until check-out) so "still parked" can be
        // queried with isNull — older transactions lack the field
        // entirely and so never show up as open.
        'time_out': timeOut == null ? null : Timestamp.fromDate(timeOut!),
        if (checkedOutByName != null) 'checked_out_by_name': checkedOutByName,
        // Set when the whole visit (time in + chosen time out) is
        // recorded on one receipt — see ReceiptPreviewDrawer.
        if (extraFee > 0) ...{
          'extra_hours': extraHours,
          'extra_fee': extraFee,
          'extra_payment_method': extraPaymentMethod ?? paymentMethod,
          if (extraPaymentRef != null) 'extra_payment_ref': extraPaymentRef,
        },
        if (plannedHours != null) 'planned_hours': plannedHours,
        if (geoLat != null && geoLng != null) ...{
          'geo_lat': geoLat,
          'geo_lng': geoLng,
          if (geoAccuracy != null) 'geo_accuracy': geoAccuracy,
        },
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
      collectorId: d['collector_id'] as String?,
      collectorName: _name(d['collector_name']),
      paymentMethod: PaymentMethod.normalize(d['payment_method'] as String?),
      paymentRef: d['payment_ref'] as String?,
      source: d['source'] == EntrySource.rfid ? EntrySource.rfid : EntrySource.manual,
      rfidTagKey: d['rfid_tag_key'] as String?,
      timeOut: (d['time_out'] as Timestamp?)?.toDate(),
      checkedOutByName: _name(d['checked_out_by_name']),
      checkedOutBy: d['checked_out_by'] as String?,
      tracksCheckout: d.containsKey('time_out'),
      extraHours: (d['extra_hours'] as num?)?.toInt() ?? 0,
      extraFee: (d['extra_fee'] as num?)?.toDouble() ?? 0,
      extraPaymentMethod: d['extra_payment_method'] == null
          ? null
          : PaymentMethod.normalize(d['extra_payment_method'] as String?),
      extraPaymentRef: d['extra_payment_ref'] as String?,
      lostTicketFee: (d['lost_ticket_fee'] as num?)?.toDouble() ?? 0,
      plannedHours: (d['planned_hours'] as num?)?.toInt(),
      geoLat: (d['geo_lat'] as num?)?.toDouble(),
      geoLng: (d['geo_lng'] as num?)?.toDouble(),
      geoAccuracy: (d['geo_accuracy'] as num?)?.toDouble(),
    );
  }
}

/// How a transaction was paid. Digital payments are recorded, not
/// processed — the collector checks the driver's GCash/Maya confirmation
/// screen and types its reference number in.
class PaymentMethod {
  static const cash = 'cash';
  static const gcash = 'gcash';
  static const maya = 'maya';

  static const all = [cash, gcash, maya];

  static String normalize(String? v) => all.contains(v) ? v! : cash;

  static String label(String method) => switch (method) {
        gcash => 'GCash',
        maya => 'Maya',
        _ => 'Cash',
      };
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
      description: _titleCaseLegacy(d['description'] ?? ''),
      timestamp: (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      pendingSync: doc.metadata.hasPendingWrites,
      previousValue: (d['previous_value'] as num?)?.toDouble(),
      newValue: (d['new_value'] as num?)?.toDouble(),
    );
  }

  /// Entries written before the event texts were title-cased ("Time out
  /// ABC123…", "ABC123 earned 3 pts…") show in the new style too.
  static String _titleCaseLegacy(String s) {
    const exact = {
      'Collector signed in': 'Collector Signed In',
      'Collector signed out': 'Collector Signed Out',
      'Face ID enrolled on device': 'Face ID Enrolled on Device',
      'Connection restored background sync resumed':
          'Connection Restored Background Sync Resumed',
      'Connection lost entering offline logging mode':
          'Connection Lost Entering Offline Logging Mode',
    };
    final hit = exact[s];
    if (hit != null) return hit;
    return s
        .replaceFirst(RegExp(r'^Time in '), 'Time In ')
        .replaceFirst(RegExp(r'^Time out '), 'Time Out ')
        .replaceFirst(RegExp(r'^Searched logs for '), 'Searched Logs For ')
        .replaceFirstMapped(RegExp(r'^(.+?) earned (\S+) pts\b'),
            (m) => '${m[1]} Earned ${m[2]} Pts')
        .replaceFirst(' Pts (paid ', ' Pts (Paid ')
        .replaceFirst(' Pts (fee ', ' Pts (Fee ');
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
  static const blotterEntry = 'BLOTTER_ENTRY';
  static const driverPortalPin = 'DRIVER_PORTAL_PIN';
  static const checkOut = 'CHECK_OUT';
}

/// How a transaction's vehicle was identified at the curb.
class EntrySource {
  static const rfid = 'rfid';
  static const manual = 'manual';
}

/// "2 Hours 15 Mins" / "45 Mins" — a stay's length for receipts and logs.
String formatStay(Duration d) {
  final mins = d.inMinutes < 0 ? 0 : d.inMinutes;
  final h = mins ~/ 60, m = mins % 60;
  if (h == 0) return '$m Mins';
  return m == 0 ? '$h Hours' : '$h Hours $m Mins';
}

/// Money collected per payment method across [txs] — the check-in fee
/// counts under its own method and any overtime under the method it was
/// paid with, which can differ.
Map<String, double> amountsByMethod(Iterable<ParkingTransaction> txs) {
  final out = <String, double>{};
  for (final tx in txs) {
    out[tx.paymentMethod] =
        (out[tx.paymentMethod] ?? 0) + tx.fee + tx.lostTicketFee;
    if (tx.extraFee > 0) {
      final m = tx.extraPaymentMethod ?? tx.paymentMethod;
      out[m] = (out[m] ?? 0) + tx.extraFee;
    }
  }
  return {
    for (final m in PaymentMethod.all)
      if (out.containsKey(m)) m: out[m]!,
  };
}

/// Stored name → display form ("carlos s espin" → "Carlos S. Espin"), or
/// null when missing/blank.
String? _name(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? formatPersonName(raw) : null;
