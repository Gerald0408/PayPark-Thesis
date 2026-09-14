import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
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
