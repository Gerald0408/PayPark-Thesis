import 'package:flutter/material.dart';

/// Vehicle types with fixed municipal ordinance rates (read-only for collector).
enum VehicleType {
  tricycle('Tricycle', Icons.electric_rickshaw, 50.0),
  // Icons below were mismatched to their labels (Van showed a plain car,
  // Truck showed a shuttle-van) — rotated so each shape actually matches
  // its name.
  sedan('Van', Icons.airport_shuttle, 100.0),
  van('Truck', Icons.local_shipping, 150.0),
  truck('10 Wheeler Truck', Icons.fire_truck, 200.0);

  const VehicleType(this.label, this.icon, this.fee);
  final String label;
  final IconData icon;
  final double fee;

  static VehicleType fromLabel(String label) => VehicleType.values.firstWhere(
        (v) => v.label == label,
        orElse: () => VehicleType.sedan,
      );
}

/// Commercial parking zones monitored by the collector.
class Zone {
  const Zone({required this.id, required this.name, required this.capacity});
  final String id;
  final String name;
  final int capacity;
}

const List<Zone> kZones = [
  Zone(id: 'savemore', name: 'Savemore Hub', capacity: 40),
  Zone(id: 'puregold', name: 'Puregold Hub', capacity: 55),
  Zone(id: 'public_market', name: 'Public Market', capacity: 30),
  Zone(id: 'marson', name: 'Marson', capacity: 25),
];

/// Ordinance reference shown in the fee matrix screen.
const String kOrdinanceRef = 'Municipal Ordinance No. 2024-07';

/// Fixed loyalty-point redemption tiers, as a **percentage of whatever
/// this transaction's fee actually is**, ascending — a customer can only
/// redeem toward one of these exact percentages, never a custom/partial
/// one. Percentage-of-fee rather than a fixed peso amount (the previous
/// [50, 100, 150, 200] pesos) so the same four tiers scale correctly
/// across every vehicle type's own fee (₱50 tricycle up to ₱200 10-
/// wheeler) instead of the higher tiers being unreachable for a cheaper
/// vehicle type.
///
/// What a tier costs in points is fixed and flat — see
/// [redemptionPointsCost] — the same number as the percentage itself
/// (25% off costs 25 points, 100% off costs 100), regardless of the
/// vehicle's fee. A redeemed transaction also earns no new points (see
/// VehicleRegistry.touch), so redeeming is pure spend, never a wash.
const List<int> kRedemptionTiers = [25, 50, 75, 100];

/// Flat points cost of redeeming [tier] — same number as the percentage
/// itself (see [kRedemptionTiers]'s doc), not scaled by the vehicle's fee.
double redemptionPointsCost(int tier) => tier.toDouble();

/// Receipt header lines.
const List<String> kReceiptHeader = [
  'Official Parking Receipt',
];

/// Closing lines printed at the bottom of every receipt, on-screen and
/// on paper. The contact number isn't fixed here anymore — it follows
/// whichever collector actually processed the transaction (see
/// ReceiptPreviewDrawer._receiptClosingLines), not one shared business
/// line.
const List<String> kReceiptFooter = [
  'THANK YOU FOR PARKING WITH US!',
  'HAVE A GREAT DAY!',
];
