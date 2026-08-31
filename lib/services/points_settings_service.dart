import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/transaction.dart';
import 'firestore_service.dart';

/// Live, admin-editable RFID loyalty-points earn rate, synced through
/// `settings/points` so every device agrees on the same rate —
/// firestore.rules restricts writes to the admin account.
class PointsSettingsService extends ChangeNotifier {
  PointsSettingsService._();
  static final PointsSettingsService instance = PointsSettingsService._();

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('settings').doc('points');

  /// ₱20 paid = 1 point by default (i.e. 0.5 points per ₱10), until an
  /// admin overrides the rate.
  double _pesoPerPoint = 20;
  StreamSubscription? _sub;

  double get pesoPerPoint => _pesoPerPoint;

  /// Call once after Firebase.initializeApp(), alongside
  /// YosRepository.instance.init() and FeeSettingsService.instance.init().
  Future<void> init() async {
    _sub = _doc.snapshots(includeMetadataChanges: true).listen(
      (snap) {
        final rate = snap.data()?['peso_per_point'];
        if (rate is num && rate > 0) _pesoPerPoint = rate.toDouble();
        notifyListeners();
      },
      // This subscribes at app startup (see main.dart), before Firebase
      // Auth necessarily has a resolved session — settings/points
      // requires hasFaceId() per firestore.rules, so a listener attached
      // while signed out (or before a resumed session's token is
      // recognized yet) hits a permission-denied on that very first
      // listen. An unhandled stream error here would surface as an
      // uncaught exception (a red screen) instead of just falling back
      // to the default rate until a real session actually reconnects it.
      onError: (Object e) =>
          debugPrint('settings/points stream error (ignored): $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Points earned for a transaction that charged [fee] — a straight
  /// fraction of the rate, e.g. a ₱50 fee at the default ₱20/point rate
  /// earns 2.5 points. Deliberately not rounded down: an admin-set rate
  /// can still earn a fraction of a point, and flooring that away would
  /// zero out smaller vehicle types entirely instead of scaling with
  /// them. This same rate also prices redemption (see kRedemptionTiers
  /// in core/constants.dart) — one shared rate, not two to keep in sync.
  double pointsForFee(double fee) => fee / _pesoPerPoint;

  /// Admin-only per firestore.rules — sets a new rate, synced to every
  /// device. Affects both how many points a fee earns and how many
  /// points each redemption tier (see kRedemptionTiers) costs, since the
  /// two share this one rate.
  Future<void> setPesoPerPoint(double value) async {
    final previous = _pesoPerPoint;
    await _doc.set({'peso_per_point': value}, SetOptions(merge: true));
    await YosRepository.instance.logAudit(
      AuditAction.pointsRateUpdated,
      'RFID points rate set to ₱${value.toStringAsFixed(0)} per point',
      previousValue: previous,
      newValue: value,
    );
  }
}

/// Shared display formatting for a points value, now that balances can be
/// fractional (e.g. 0.5, 0.75) — whole numbers show with no decimal
/// ("5"), fractional ones show up to 2 decimal places with trailing
/// zeros trimmed ("0.5", not "0.50"). Used by every screen that shows a
/// points balance (RfidPointsScreen, RegisterVehicleScreen,
/// ReceiptPreviewDrawer) so they never disagree on formatting.
String formatPoints(double points) {
  if (points == points.roundToDouble()) return points.toStringAsFixed(0);
  var s = points.toStringAsFixed(2);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}
