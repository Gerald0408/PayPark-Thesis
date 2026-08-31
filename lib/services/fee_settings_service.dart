import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
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
  StreamSubscription? _sub;

  /// Call once after Firebase.initializeApp(), alongside
  /// YosRepository.instance.init().
  Future<void> init() async {
    _sub = _doc.snapshots(includeMetadataChanges: true).listen(
      (snap) {
        final data = snap.data();
        _overrides = {
          for (final t in VehicleType.values)
            if (data?[t.name] is num)
              t.name: (data![t.name] as num).toDouble(),
        };
        notifyListeners();
      },
      // This subscribes at app startup (see main.dart), before Firebase
      // Auth necessarily has a resolved session — settings/fees requires
      // hasFaceId() per firestore.rules, so a listener attached while
      // signed out (or before a resumed session's token is recognized
      // yet) hits a permission-denied on that very first listen. An
      // unhandled stream error here would surface as an uncaught
      // exception (a red screen) instead of just falling back to the
      // ordinance defaults until a real session actually reconnects it.
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

  /// Admin-only per firestore.rules — set a new rate for [type], synced to
  /// every device. Affects new entries going forward only; past
  /// transactions keep the fee they were logged with.
  Future<void> setFee(VehicleType type, double fee) async {
    final previous = feeFor(type);
    await _doc.set({type.name: fee}, SetOptions(merge: true));
    await YosRepository.instance.logAudit(
      AuditAction.feeUpdated,
      '${type.label} fee set to ₱${fee.toStringAsFixed(0)}',
      previousValue: previous,
      newValue: fee,
    );
  }
}
