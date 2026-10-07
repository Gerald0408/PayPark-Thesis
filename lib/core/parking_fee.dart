/// What one visit costs, worked out from its time in and time out.
///
/// Pure arithmetic — no Firebase, no settings lookups — so it can be
/// tested directly (see test/parking_fee_test.dart) and shown step by step
/// on the time-out receipt. FeeSettingsService.quote fills in the current
/// rates.
class ParkingFee {
  const ParkingFee({
    required this.stay,
    required this.baseFee,
    required this.baseHours,
    required this.extraHours,
    required this.extraRate,
    required this.lostTicketFee,
    required this.discount,
  });

  /// Time in → time out.
  final Duration stay;

  /// Covers the first [baseHours] hours.
  final double baseFee;
  final int baseHours;

  /// Hours started after the base hours — each one counts as a full hour
  /// (e.g. 3 base hours: 3h00m → 0, 3h01m → 1, 4h01m → 2).
  final int extraHours;
  final double extraRate;
  double get extraFee => extraHours * extraRate;

  /// Charged only when the driver can't present the time-in ticket.
  final double lostTicketFee;

  /// Points discount, taken off the base fee only (never below zero).
  final double discount;

  double get total =>
      (baseFee - discount).clamp(0, baseFee) + extraFee + lostTicketFee;
}

/// Prices a stay of [stay] at the given rates. A negative stay (time out
/// before time in) is treated as zero.
ParkingFee computeParkingFee({
  required Duration stay,
  required double baseFee,
  required int baseHours,
  required double extraRate,
  double lostTicketFee = 0,
  double discount = 0,
}) {
  final minutes = stay.isNegative ? 0 : stay.inMinutes;
  final over = minutes - baseHours * 60;
  return ParkingFee(
    stay: stay.isNegative ? Duration.zero : stay,
    baseFee: baseFee,
    baseHours: baseHours,
    extraHours: over <= 0 ? 0 : (over / 60).ceil(),
    extraRate: extraRate,
    lostTicketFee: lostTicketFee,
    discount: discount,
  );
}
