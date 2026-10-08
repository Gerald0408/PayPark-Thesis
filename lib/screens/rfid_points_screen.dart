import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/points_settings_service.dart' show formatPoints;
import '../services/registry_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/visit_flow.dart';
import '../widgets/glow_effects.dart';
import 'registry_screen.dart';

enum _SortMode { pointsDesc, nameAsc }

/// RFID loyalty points view: every registered vehicle enrolled with an
/// RFID tag (see RegisteredVehicle.rfidTag), searchable by plate, driver
/// name, or tag ID, with its points balance front and center. Points
/// themselves are earned automatically (VehicleRegistry.touch) and
/// redeemed from the receipt drawer in vehicle_entry_screen.dart — this
/// screen is view + enrollment management, not a manual credit/debit
/// tool.
class RfidPointsScreen extends StatefulWidget {
  const RfidPointsScreen({super.key});

  @override
  State<RfidPointsScreen> createState() => _RfidPointsScreenState();
}

class _RfidPointsScreenState extends State<RfidPointsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  _SortMode _sort = _SortMode.pointsDesc;

  // Same reasoning, for the registry list below — the search box's own
  // setState on every keystroke would otherwise hand its StreamBuilder a
  // brand-new Stream instance each time, the exact trigger for Flutter's
  // "'_dependents.isEmpty': is not true" crash.
  late final Stream<List<RegisteredVehicle>> _vehicles =
      VehicleRegistry.instance.all();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Fires when the search box receives an Enter/Return keystroke — which
  /// is exactly how a plug-and-play USB RFID reader reports a scan: it
  /// enumerates as a USB-HID keyboard and "types" the tag ID followed by
  /// Enter into whichever field has focus. No plugin or permission needed,
  /// just a focused text field — see the autofocus below. A card whose tag
  /// doesn't match anything just clears back to an empty search.
  Future<void> _onScan(String raw) async {
    final tag = raw.trim();
    if (tag.isEmpty) return;
    final match = await VehicleRegistry.instance.lookupByRfid(tag);
    if (!mounted) return;
    _search.clear();
    if (match == null) {
      Toast.error(context,
          t('No vehicle enrolled with tag "$tag".',
              'Walang sasakyang naka-enroll sa tag na "$tag".'));
      _searchFocus.requestFocus();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RegisterVehicleScreen(existing: match)));
    if (mounted) _searchFocus.requestFocus();
  }

  /// Redemption tiers [v]'s balance can afford, ascending — each
  /// tier's points cost is flat (see [redemptionPointsCost]), not scaled
  /// by fee. Same shape as ReceiptPreviewDrawer._eligibleTiers.
  List<int> _eligibleTiers(RegisteredVehicle v) {
    return kRedemptionTiers
        .where((t) => redemptionPointsCost(t) <= v.points)
        .toList();
  }

  /// Builds today's transaction for [v] exactly like an RFID tap at
  /// Vehicle Entry would, then opens the receipt sheet with [tier] already
  /// selected — reached from the points/discount popup's per-tier Redeem
  /// button (see _PointsDiscountDialog), so there's nothing left for the
  /// collector to configure, just confirm and print.
  Future<void> _redeem(RegisteredVehicle v, int tier) async {
    final open = await YosRepository.instance.openVisitFor(v.plateNumber);
    if (!mounted) return;
    // Points come off the fee, which is paid at time out — a vehicle that
    // isn't parked yet gets its time-in ticket first.
    if (open == null) {
      Toast.info(
          context,
          t('Points are used at TIME OUT. Time the vehicle in first.',
              'Ginagamit ang points sa paglabas. I-time in muna ang sasakyan.'));
    }
    await runVisitFlow(
      context,
      open: open,
      redeemTier: tier,
      prepareCheckIn: () async => (
        YosRepository.instance.buildTransaction(
          driverName: v.driverName,
          plateNumber: v.plateNumber,
          type: VehicleType.fromLabel(v.vehicleType),
          zoneId: v.defaultZoneId,
        ),
        v,
      ),
    );
  }

  /// Read-only-until-you-tap-Redeem summary of [v]'s points balance and
  /// which discount tiers it currently qualifies for — reached by tapping
  /// anywhere on its card except the edit pencil (see the card's own
  /// onTap). Popping this dialog with an [int] (a chosen tier) chains
  /// straight into [_redeem]; popping with nothing just closes it.
  Future<void> _showPointsDialog(RegisteredVehicle v) async {
    final tier = await showDialog<int>(
      context: context,
      builder: (_) =>
          _PointsDiscountDialog(vehicle: v, eligibleTiers: _eligibleTiers(v)),
    );
    if (tier != null) _redeem(v, tier);
  }

  List<RegisteredVehicle> _apply(List<RegisteredVehicle> list) {
    final enrolled = list.where((v) => v.rfidTag != null);
    final q = _search.text.trim().toUpperCase();
    final out = (q.isEmpty
            ? enrolled
            : enrolled.where((v) =>
                v.plateNumber.toUpperCase().contains(q) ||
                v.driverName.toUpperCase().contains(q) ||
                (v.rfidTag ?? '').toUpperCase().contains(q)))
        .toList();
    switch (_sort) {
      case _SortMode.pointsDesc:
        out.sort((a, b) => b.points.compareTo(a.points));
        break;
      case _SortMode.nameAsc:
        out.sort((a, b) =>
            a.driverName.toUpperCase().compareTo(b.driverName.toUpperCase()));
        break;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('RFID Points', 'RFID Points'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<List<RegisteredVehicle>>(
            stream: _vehicles,
            builder: (context, snap) {
              final list = _apply(snap.data ?? const []);
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  TextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _onScan,
                    decoration: InputDecoration(
                      hintText: t('Scan a card, or search plate/driver/tag',
                          'Mag-scan ng card, o maghanap ng plaka/driver/tag'),
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: const Icon(Icons.contactless_rounded),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                      t(
                          'Plug in the USB card reader and tap a card — it '
                              'looks up the vehicle automatically. You can still '
                              'search by hand above.',
                          'I-plug ang USB card reader at i-tap ang card — '
                              'awtomatiko nitong hahanapin ang sasakyan. '
                              'Maaari ka pa ring maghanap nang manu-mano sa itaas.'),
                      style: TextStyle(color: YosColors.sub, fontSize: 11)),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: DropdownButton<_SortMode>(
                      value: _sort,
                      underline: const SizedBox.shrink(),
                      items: [
                        DropdownMenuItem(
                            value: _SortMode.pointsDesc,
                            child: Text(t('Most Points', 'Pinakamaraming Points'))),
                        DropdownMenuItem(
                            value: _SortMode.nameAsc,
                            child: Text(t('Name A–Z', 'Pangalan A–Z'))),
                      ],
                      onChanged: (v) => setState(() => _sort = v ?? _sort),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!snap.hasData)
                    Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: Center(
                          child: CircularProgressIndicator(
                              color: YosColors.accent)),
                    )
                  else if (list.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: Center(
                        child: Text(
                            t(
                                'No RFID-enrolled vehicles yet.\nAdd an RFID '
                                    "tag from a vehicle's registration to get "
                                    'started.',
                                'Wala pang RFID-enrolled na sasakyan.\nMagdagdag '
                                    'ng RFID tag mula sa rehistrasyon ng sasakyan '
                                    'para magsimula.'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: YosColors.sub)),
                      ),
                    )
                  else
                    for (var i = 0; i < list.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: PopIn(
                          delayMs: 40 + i * 40,
                          child: GlassCard(
                            // Shows the points/discount summary now,
                            // not the edit form — editing moved to its
                            // own pencil icon below (see _tiles), so a
                            // plain card tap can't land the collector
                            // in a full edit screen by accident.
                            onTap: () => _showPointsDialog(list[i]),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 52,
                                      height: 52,
                                      decoration: BoxDecoration(
                                          color: YosColors.mint,
                                          borderRadius:
                                              BorderRadius.circular(16)),
                                      child: Icon(Icons.nfc_rounded,
                                          color: YosColors.ink, size: 26),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(list[i].plateNumber,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 15,
                                                  letterSpacing: 1.5)),
                                          Text(list[i].driverName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  color: YosColors.sub,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600)),
                                          Text('Tag ${list[i].rfidTag}',
                                              style: TextStyle(
                                                  color: YosColors.sub,
                                                  fontSize: 11)),
                                        ],
                                      ),
                                    ),
                                    // No edit icon here — this card is
                                    // read-only, points/discounts-only
                                    // (see the card's own onTap);
                                    // editing a vehicle now happens
                                    // from Registered Vehicles instead.
                                    // Same fixed-width column on the
                                    // right of every card, with the
                                    // figures left-aligned inside it,
                                    // so each balance starts at the
                                    // same spot down the list. FittedBox
                                    // shrinks a huge balance instead of
                                    // overflowing.
                                    SizedBox(
                                      width: 96,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                                formatPoints(list[i].points),
                                                maxLines: 1,
                                                style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 24,
                                                    fontFeatures: const [
                                                      FontFeature
                                                          .tabularFigures()
                                                    ],
                                                    color:
                                                        YosColors.accentDeep)),
                                          ),
                                          Text(t('points', 'points'),
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: YosColors.sub)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Points balance + per-tier discount eligibility for one enrolled
/// vehicle — reached by tapping its card on [RfidPointsScreen] (see
/// _showPointsDialog). Popping with an [int] (one of kRedemptionTiers)
/// means the collector tapped that tier's Redeem button; popping with
/// nothing just closes it without redeeming anything.
class _PointsDiscountDialog extends StatelessWidget {
  const _PointsDiscountDialog(
      {required this.vehicle, required this.eligibleTiers});

  final RegisteredVehicle vehicle;
  final List<int> eligibleTiers;

  @override
  Widget build(BuildContext context) {
    final fee = FeeSettingsService.instance
        .feeFor(VehicleType.fromLabel(vehicle.vehicleType));

    return Dialog(
      backgroundColor: YosColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // Capped and scrollable rather than left to size itself — the tier
      // list plus balance card could otherwise overflow a short screen
      // and spill past the dialog's own bounds into whatever's behind it.
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 6, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(t('Points & discounts', 'Points at Diskwento'),
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              color: YosColors.ink)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded,
                          color: YosColors.sub, size: 20),
                      tooltip: t('Close', 'Isara'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${vehicle.plateNumber} · ${vehicle.driverName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: YosColors.sub,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 12),
                      decoration: BoxDecoration(
                          color: YosColors.accentSoft,
                          borderRadius: BorderRadius.circular(14)),
                      child: Column(
                        children: [
                          Text(formatPoints(vehicle.points),
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                  color: YosColors.accentDeep)),
                          Text(t('Current Points Balances', 'kasalukuyang balanse ng points'),
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: YosColors.onAccentSoft
                                      .withValues(alpha: 0.72))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(t('Discount tiers', 'Mga Tier ng Diskwento'),
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 12)),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Column(
                  children: [
                    for (final tier in kRedemptionTiers)
                      _TierRow(
                        tier: tier,
                        discount: fee * tier / 100,
                        pointsCost: redemptionPointsCost(tier),
                        eligible: eligibleTiers.contains(tier),
                        onRedeem: () => Navigator.of(context).pop(tier),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TierRow extends StatelessWidget {
  const _TierRow({
    required this.tier,
    required this.discount,
    required this.pointsCost,
    required this.eligible,
    required this.onRedeem,
  });

  /// Which [kRedemptionTiers] percentage this row is, purely to report
  /// back via [onRedeem] — not shown on the row itself, which displays
  /// only the peso amount (see [discount]).
  final int tier;

  /// Pesos this percentage actually discounts, given this vehicle's own
  /// fee — shown instead of the raw percentage so the collector reads a
  /// peso figure directly rather than doing the math themselves.
  final double discount;
  final double pointsCost;
  final bool eligible;
  final VoidCallback onRedeem;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: eligible ? YosColors.accentSoft : YosColors.surfaceHigh,
          borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('₱${discount.toStringAsFixed(0)} off',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: YosColors.ink)),
                // Always the flat threshold itself, not "needs X more" —
                // a customer looking down this list should see up front
                // what it takes to unlock any tier, not just how far
                // short they are of the one they're currently looking at.
                Text(
                    t('Requires ${formatPoints(pointsCost)} points',
                        'Kailangan ng ${formatPoints(pointsCost)} points'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: YosColors.sub)),
              ],
            ),
          ),
          if (eligible)
            Material(
              color: YosColors.accent,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: onRedeem,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Text(t('Redeem', 'I-redeem'),
                      style: TextStyle(
                          color: YosColors.onAccent,
                          fontWeight: FontWeight.w800,
                          fontSize: 12)),
                ),
              ),
            )
          else
            Icon(Icons.lock_outline_rounded, size: 16, color: YosColors.sub),
        ],
      ),
    );
  }
}
