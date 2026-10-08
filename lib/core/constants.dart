import 'package:flutter/material.dart';

/// Vehicle types and their default rates: the base fee covers the first
/// [kDefaultBaseHours] hours, then [extraHourFee] per hour started after
/// that. Admins can change all of these in Fee Matrix
/// (FeeSettingsService) — these are only the starting values.
///
/// New enum names (not the old tricycle/sedan/truck) on purpose: fee
/// overrides in settings/fees are keyed by name, so the old types' saved
/// overrides can't silently replace these new rates.
enum VehicleType {
  motorcycle('Motorcycle', Icons.two_wheeler, 50.0, 10.0),
  closedVan('Closed Van', Icons.airport_shuttle, 100.0, 15.0),
  car('Forward / Elf', Icons.directions_car, 150.0, 15.0),
  van('Trailer Truck', Icons.local_shipping, 200.0, 25.0);

  const VehicleType(this.label, this.icon, this.fee, this.extraHourFee);
  final String label;
  final IconData icon;

  /// Default base fee — covers the first [kDefaultBaseHours] hours.
  final double fee;

  /// Default charge per hour started past the base hours.
  final double extraHourFee;

  /// Picture shown under the name on this type's picker tile, or
  /// null for none.
  String? get backgroundImage => switch (this) {
        VehicleType.motorcycle => 'assets/vehicles/motorcycle.png',
        VehicleType.closedVan => 'assets/vehicles/closed_van.png',
        VehicleType.car => 'assets/vehicles/forward_elf.png',
        VehicleType.van => 'assets/vehicles/trailer_truck.png',
      };

  /// The same three types under the names they had before Oct 2026 —
  /// only renamed, so records saved with these read as the new names
  /// (see [currentLabel]).
  static const _renamedLabels = {
    'Motorcycle / Scooter': VehicleType.motorcycle,
    'Sedan / Hatchback / SUV': VehicleType.car,
    'Delivery Van / Light Truck': VehicleType.van,
  };

  /// Labels saved on transactions/registered vehicles before the current
  /// types existed, mapped to the closest current type.
  static const _legacyLabels = {
    'Closed Van, Jeep, SUV, Tricycle': VehicleType.car,
    'Forward/Elf': VehicleType.car,
    'Trailer Truck/Ten Wheeler Truck': VehicleType.van,
    'Sedan': VehicleType.car,
    // Briefly one type (Oct 2026) before Closed Van got its own rate —
    // priced as a motorcycle then, and shown as recorded.
    'Closed Van / Motorcycle': VehicleType.motorcycle,
  };

  static VehicleType fromLabel(String label) =>
      VehicleType.values.where((v) => v.label == label).firstOrNull ??
      _renamedLabels[label] ??
      _legacyLabels[label] ??
      VehicleType.car;

  /// [saved] as it should be shown: a renamed type's old label becomes
  /// its current one; anything else (including older legacy labels, which
  /// were genuinely different categories) is kept as recorded.
  static String currentLabel(String saved) =>
      _renamedLabels[saved]?.label ?? saved;
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
  Zone(id: 'public_market', name: 'Red Camia Store (RCS)', capacity: 30),
  Zone(id: 'marson', name: 'Marson', capacity: 25),
];

/// Ordinance reference shown in the fee matrix screen.
const String kOrdinanceRef = 'Municipal Ordinance No. 2024-07';

/// Issuing barangay — printed as the letterhead on every exported PDF (see
/// PdfExportService) alongside the barangay seal (assets/icon/logo.png).
const String kOrgName = 'PayPark';
const String kOrgAddress =
    'Barangay San Nicolas Poblacion, Concepcion, Tarlac';

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

/// Where drivers sign in to see their points and parking history — the
/// Firebase Hosting site for this project (see web_driver/ and
/// lib/main_driver.dart). Shown to collectors when they set up a PIN.
const String kDriverPortalUrl = 'concepcion-pay-parking.web.app';

/// Default hours the check-in fee covers before extra-hour charges start
/// — admins can change it in Fee Matrix (FeeSettingsService.baseHours).
const int kDefaultBaseHours = 3;

/// Default charge for a lost time-in ticket, printed on every ticket and
/// added at time out when the driver can't present it — admins can
/// change it in Fee Matrix (FeeSettingsService.lostTicketFee).
const double kDefaultLostTicketFee = 100.0;
