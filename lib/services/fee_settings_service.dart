import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/parking_fee.dart';
import '../models/transaction.dart';
import 'firestore_service.dart';

/// Live, admin-editable overrides for the per-vehicle-type fees that
/// [VehicleType] otherwise hardcodes from the municipal ordinance. Synced
/// through a single `settings/fees` doc so every device sees the same
/// rates — firestore.rules restricts writes to the admin account (see
/// isAdmin() there), everyone else gets read-only access.
class FeeSettingsService extends ChangeNotifier {
  FeeSettingsService._();
  static final FeeSettingsService instance = FeeSettingsService._();

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('settings').doc('fees');

  Map<String, double> _overrides = {};
  // The rate each override replaced, and when — written alongside the
  // override itself in [setFee] as `${type.name}_previous` /
  // `${type.name}_updated_at`, so FeesScreen's details dialog can show
  // "last price" + "updated" without querying the audit log.
  Map<String, double> _previousOverrides = {};
  Map<String, DateTime> _updatedAt = {};
  StreamSubscription? _sub;

  /// Call once after Firebase.initializeApp(), alongside
  /// YosRepository.instance.init().
  Future<void> init() async {
    // Re-derived from authStateChanges() — same pattern as
    // YosRepository.currentUserIsAdmin — rather than a single
    // `_doc.snapshots()` attached once at app startup. This subscribes
    // before Firebase Auth necessarily has a resolved session, and
    // settings/fees requires hasFaceId() per firestore.rules, so a
    // listener attached while signed out (or before a resumed session's
    // token is recognized yet) hits a permission-denied on that very
    // first listen. Firestore closes the *inner* snapshots() stream for
    // good after that error, so subscribing directly to it here — as this
    // used to — meant _overrides stayed empty forever even once a real
    // admin session came up later and an edit actually saved: the write
    // would succeed but this listener was already dead, so feeFor() kept
    // returning the hardcoded ordinance default no matter what got
    // written. Re-deriving from authStateChanges() instead means every
    // auth change (including the initial session restoring a moment
    // after this fires) opens a *fresh* settings/fees listener, so it
    // actually reconnects instead of just falling back to defaults
    // forever.
    _sub = FirebaseAuth.instance.authStateChanges().asyncExpand((user) {
      if (user == null) return const Stream.empty();
      return _doc.snapshots(includeMetadataChanges: true);
    }).listen(
      (snap) {
        final data = snap.data();
        _overrides = {
          for (final t in VehicleType.values)
            if (data?[t.name] is num)
              t.name: (data![t.name] as num).toDouble(),
        };
        _previousOverrides = {
          for (final t in VehicleType.values)
            if (data?['${t.name}_previous'] is num)
              t.name: (data!['${t.name}_previous'] as num).toDouble(),
        };
        _updatedAt = {
          for (final t in VehicleType.values)
            if (data?['${t.name}_updated_at'] is Timestamp)
              t.name: (data!['${t.name}_updated_at'] as Timestamp).toDate(),
        };
        _extraOverrides = {
          for (final t in VehicleType.values)
            if (data?['${t.name}_extra_hour'] is num)
              t.name: (data!['${t.name}_extra_hour'] as num).toDouble(),
        };
        _baseHours = data?['included_hours'] is num
            ? (data!['included_hours'] as num).toInt()
            : null;
        _lostTicketFee = data?['lost_ticket_fee'] is num
            ? (data!['lost_ticket_fee'] as num).toDouble()
            : null;
        notifyListeners();
      },
      onError: (Object e) =>
          debugPrint('settings/fees stream error (ignored): $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// The rate actually in effect for [type] right now — the admin's
  /// override if one's been set, otherwise the ordinance default baked
  /// into [VehicleType].
  double feeFor(VehicleType type) => _overrides[type.name] ?? type.fee;

  // ---------------------------------------------------------------------
  // Time-based charges: the check-in fee covers the first [baseHours];
  // each extra hour started after that costs [extraHourFeeFor], collected
  // at check-out.
  // ---------------------------------------------------------------------

  Map<String, double> _extraOverrides = {};
  int? _baseHours;

  // Stored as 'included_hours' (not the old 'base_hours'), so a value
  // saved under the previous 2-hour scheme can't override the new
  // default.
  int get baseHours => _baseHours ?? kDefaultBaseHours;

  double? _lostTicketFee;
  double get lostTicketFee => _lostTicketFee ?? kDefaultLostTicketFee;

  /// The full price of a visit by [type] from [timeIn] to [timeOut] at
  /// the current rates — see computeParkingFee for the rules.
  ParkingFee quote(
    VehicleType type,
    DateTime timeIn,
    DateTime timeOut, {
    bool lostTicket = false,
    double discount = 0,
  }) =>
      computeParkingFee(
        stay: timeOut.difference(timeIn),
        baseFee: feeFor(type),
        baseHours: baseHours,
        extraRate: extraHourFeeFor(type),
        lostTicketFee: lostTicket ? lostTicketFee : 0,
        discount: discount,
      );

  Future<void> setLostTicketFee(double fee) async {
    final previous = lostTicketFee;
    await _doc.set({'lost_ticket_fee': fee}, SetOptions(merge: true));
    _lostTicketFee = fee;
    notifyListeners();
    await YosRepository.instance.logAudit(
      AuditAction.feeUpdated,
      'Lost Ticket Fee set to ₱${fee.toStringAsFixed(0)}',
      previousValue: previous,
      newValue: fee,
    );
  }

  double extraHourFeeFor(VehicleType type) =>
      _extraOverrides[type.name] ?? type.extraHourFee;

  /// Extra hours and amount owed at check-out for a [stay] by [type].
  /// Every hour *started* past [baseHours] counts as a full hour — e.g.
  /// with 2 base hours, 2h00m owes nothing and 2h01m owes one hour.
  OvertimeCharge overtimeFor(VehicleType type, Duration stay) {
    final overMinutes = stay.inMinutes - baseHours * 60;
    final hours = overMinutes <= 0 ? 0 : (overMinutes / 60).ceil();
    final rate = extraHourFeeFor(type);
    return OvertimeCharge(hours: hours, rate: rate, amount: hours * rate);
  }

  Future<void> setExtraHourFee(VehicleType type, double fee) async {
    final previous = extraHourFeeFor(type);
    await _doc.set({'${type.name}_extra_hour': fee}, SetOptions(merge: true));
    _extraOverrides = {..._extraOverrides, type.name: fee};
    notifyListeners();
    await YosRepository.instance.logAudit(
      AuditAction.feeUpdated,
      '${type.label} Extra Hours fee set to ₱${fee.toStringAsFixed(0)}',
      previousValue: previous,
      newValue: fee,
    );
  }

  Future<void> setBaseHours(int hours) async {
    final previous = baseHours;
    await _doc.set({'included_hours': hours}, SetOptions(merge: true));
    _baseHours = hours;
    notifyListeners();
    await YosRepository.instance.logAudit(
      AuditAction.feeUpdated,
      'Base fee now covers the first $hours Hours',
      previousValue: previous.toDouble(),
      newValue: hours.toDouble(),
    );
  }

  bool hasOverride(VehicleType type) => _overrides.containsKey(type.name);

  /// The rate [type] had right before its current override — null if it's
  /// never been edited. For FeesScreen's details dialog.
  double? previousFeeFor(VehicleType type) => _previousOverrides[type.name];

  /// When [type]'s fee was last edited — null if it's never been edited.
  DateTime? updatedAtFor(VehicleType type) => _updatedAt[type.name];

  /// Admin-only per firestore.rules — set a new rate for [type], synced to
  /// every device. Affects new entries going forward only; past
  /// transactions keep the fee they were logged with. Also stamps
  /// `${type.name}_previous`/`_updated_at` on the same doc, so every
  /// device's [previousFeeFor]/[updatedAtFor] reflect this edit as soon as
  /// it syncs — same doc, no separate audit-log query needed.
  Future<void> setFee(VehicleType type, double fee) async {
    final previous = feeFor(type);
    final now = DateTime.now();
    await _doc.set({
      type.name: fee,
      '${type.name}_previous': previous,
      '${type.name}_updated_at': Timestamp.fromDate(now),
    }, SetOptions(merge: true));
    // Applied locally too, not left to wait on this device's own
    // settings/fees listener to loop the write back — that's a real
    // round trip (or at least a queued callback), and FeesScreen reads
    // straight off [_overrides] the moment its success toast fires. Once
    // the listener does come back around with the server-confirmed data
    // it just reassigns the same values, a harmless no-op.
    _overrides = {..._overrides, type.name: fee};
    _previousOverrides = {..._previousOverrides, type.name: previous};
    _updatedAt = {..._updatedAt, type.name: now};
    notifyListeners();
    await YosRepository.instance.logAudit(
      AuditAction.feeUpdated,
      '${type.label} fee set to ₱${fee.toStringAsFixed(0)}',
      previousValue: previous,
      newValue: fee,
    );
  }
}

/// What a stay owes past the hours the check-in fee covers.
class OvertimeCharge {
  const OvertimeCharge(
      {required this.hours, required this.rate, required this.amount});
  final int hours;
  final double rate;
  final double amount;
  bool get isDue => amount > 0;
}
