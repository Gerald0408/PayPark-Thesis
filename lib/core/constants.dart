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

/// Fixed loyalty-point redemption tiers, in **pesos**, ascending — a
/// customer can only redeem toward one of these exact cash amounts,
/// never a custom/partial one. The points a tier actually costs isn't
/// fixed here: it's the tier's peso value divided by
/// PointsSettingsService.pesoPerPoint, the same live, admin-editable
/// rate points are earned at — redeeming and earning deliberately share
/// one rate rather than having two to keep in sync. A balance must reach
/// at least the lowest tier's points-cost to redeem anything at all.
const List<int> kRedemptionTiers = [50, 100, 150, 200];

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
