import 'package:flutter/foundation.dart';

/// RFID loyalty-points earn rate — a fixed, uniform rate applied to every
/// vehicle type: 0.03 points earned per ₱1 of fee (an RFID tap credits
/// 3% of the fee in points). No longer admin-editable or synced through
/// Firestore — this used to be a live `settings/points`-backed rate an
/// admin could change from RfidPointsScreen's rate-editor card; that card
/// is gone now that the rate is fixed, by request. Redemption tiers price
/// separately and flatly (see redemptionPointsCost in core/constants.dart)
/// — this rate only governs earning.
class PointsSettingsService extends ChangeNotifier {
  PointsSettingsService._();
  static final PointsSettingsService instance = PointsSettingsService._();

  /// ₱1 of fee earns this many points — 0.03, i.e. an RFID tap credits 3%
  /// of the fee in points.
  static const double pointsPerPeso = 0.03;

  /// The inverse of [pointsPerPeso], kept for any call site that wants
  /// the "pesos per point" shape instead.
  double get pesoPerPoint => 1 / pointsPerPeso;

  /// No-op now that there's no live setting to subscribe to — kept only
  /// so main.dart's startup sequence (alongside YosRepository.init() and
  /// FeeSettingsService.init()) doesn't need to change.
  Future<void> init() async {}

  /// Points earned for a transaction that charged [fee] — a straight
  /// fraction of the fixed rate, e.g. a ₱50 fee earns 2.5 points.
  /// Deliberately not rounded down: a fraction of a point still counts,
  /// and flooring that away would zero out smaller vehicle types entirely
  /// instead of scaling with them.
  double pointsForFee(double fee) => fee * pointsPerPeso;
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
