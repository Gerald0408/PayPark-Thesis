import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/points_settings_service.dart';
import '../services/registry_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/glow_effects.dart';
import 'registry_screen.dart';
import 'vehicle_entry_screen.dart';

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

  // Same rationale as FeesScreen — captured once so StreamBuilder sees a
  // stable Stream instance across rebuilds.
  late final Stream<bool> _isAdminStream =
      YosRepository.instance.currentUserIsAdmin;

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
      Toast.error(context, 'No vehicle enrolled with tag "$tag".');
      _searchFocus.requestFocus();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RegisterVehicleScreen(existing: match)));
    if (mounted) _searchFocus.requestFocus();
  }

  /// Redemption is a fixed-tier system (kRedemptionTiers, in pesos),
  /// capped by [v]'s own vehicle type fee (see
  /// ReceiptPreviewDrawer._vehicleFee) — [v] is eligible for the quick
  /// Redeem button only once both its balance (converted to points at
  /// the live earn rate) and its type's own fee clear the lowest tier.
  bool _canQuickRedeem(RegisteredVehicle v) {
    final fee = FeeSettingsService.instance
        .feeFor(VehicleType.fromLabel(v.vehicleType));
    final lowestTierCost =
        kRedemptionTiers.first / PointsSettingsService.instance.pesoPerPoint;
    return v.points >= lowestTierCost && fee >= kRedemptionTiers.first;
  }

  /// Builds today's transaction for [v] exactly like an RFID tap at
  /// Vehicle Entry would, then opens the same receipt sheet with the
  /// highest tier its balance covers already selected (autoRedeemMax) —
  /// this button only shows once [v] is redemption-eligible at all (see
  /// _canQuickRedeem), so there's nothing left for the collector to
  /// configure, just confirm and print.
  void _redeem(RegisteredVehicle v) {
    final tx = YosRepository.instance.buildTransaction(
      driverName: v.driverName,
      plateNumber: v.plateNumber,
      type: VehicleType.fromLabel(v.vehicleType),
      zoneId: v.defaultZoneId,
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ReceiptPreviewDrawer(
        tx: tx,
        registered: v,
        autoRedeemMax: true,
        onDone: () => Navigator.of(sheetContext).pop(),
      ),
    );
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
        title: const Text('RFID points',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<bool>(
            stream: _isAdminStream,
            initialData: false,
            builder: (context, adminSnap) {
              final isAdmin = adminSnap.data ?? false;
              return StreamBuilder<List<RegisteredVehicle>>(
                stream: _vehicles,
                builder: (context, snap) {
                  final list = _apply(snap.data ?? const []);
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    children: [
                      if (isAdmin) ...[
                        const _RateEditor(),
                        const SizedBox(height: 16),
                      ],
                      TextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _onScan,
                        decoration: const InputDecoration(
                          hintText: 'Scan a card, or search plate/driver/tag',
                          prefixIcon: Icon(Icons.search_rounded),
                          suffixIcon: Icon(Icons.contactless_rounded),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                          'Plug in the USB card reader and tap a card — it '
                          'looks up the vehicle automatically. You can still '
                          'search by hand above.',
                          style: TextStyle(color: YosColors.sub, fontSize: 11)),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: DropdownButton<_SortMode>(
                          value: _sort,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(
                                value: _SortMode.pointsDesc,
                                child: Text('Most points')),
                            DropdownMenuItem(
                                value: _SortMode.nameAsc,
                                child: Text('Name A–Z')),
                          ],
                          onChanged: (v) =>
                              setState(() => _sort = v ?? _sort),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (!snap.hasData)
                        const Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: Center(
                              child: CircularProgressIndicator(
                                  color: YosColors.accent)),
                        )
                      else if (list.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: Center(
                            child: Text(
                                'No RFID-enrolled vehicles yet.\nAdd an RFID '
                                'tag from a vehicle\'s registration to get '
                                'started.',
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
                                onTap: () async {
                                  await Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              RegisterVehicleScreen(
                                                  existing: list[i])));
                                },
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
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
                                          child: const Icon(Icons.nfc_rounded,
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
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      fontSize: 15,
                                                      letterSpacing: 1.5)),
                                              Text(list[i].driverName,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      color: YosColors.sub,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w600)),
                                              Text('Tag ${list[i].rfidTag}',
                                                  style: const TextStyle(
                                                      color: YosColors.sub,
                                                      fontSize: 11)),
                                            ],
                                          ),
                                        ),
                                        Flexible(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                    formatPoints(
                                                        list[i].points),
                                                    maxLines: 1,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w900,
                                                        fontSize: 24,
                                                        color: YosColors
                                                            .accentDeep)),
                                              ),
                                              const Text('points',
                                                  style: TextStyle(
                                                      fontSize: 10,
                                                      color: YosColors.sub)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_canQuickRedeem(list[i])) ...[
                                      const SizedBox(height: 10),
                                      FilledButton.tonalIcon(
                                        onPressed: () => _redeem(list[i]),
                                        icon: const Icon(
                                            Icons.redeem_rounded,
                                            size: 18),
                                        label: const Text('Redeem points'),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Admin-only editable control for [PointsSettingsService.pesoPerPoint] —
/// how many pesos of fee earns 1 point every time an RFID tag is scanned
/// and matched. A plain always-visible input (not a tap-to-open dialog),
/// so "set the earn rate" is one field and one tap away, right on this
/// screen. Redemption shares this exact rate too (see kRedemptionTiers'
/// doc) — changing it here changes both how many points a scan earns
/// *and* how many points each fixed peso tier costs to redeem.
class _RateEditor extends StatefulWidget {
  const _RateEditor();

  @override
  State<_RateEditor> createState() => _RateEditorState();
}

class _RateEditorState extends State<_RateEditor> {
  late final _rate = TextEditingController(
      text: PointsSettingsService.instance.pesoPerPoint.toStringAsFixed(0));
  bool _saving = false;

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = double.tryParse(_rate.text.trim());
    if (value == null || value <= 0) {
      Toast.error(context, 'Enter a valid amount.');
      return;
    }
    setState(() => _saving = true);
    try {
      await PointsSettingsService.instance.setPesoPerPoint(value);
      if (mounted) {
        Toast.success(context,
            'Points rate updated — ₱${value.toStringAsFixed(0)} now earns 1 point.');
      }
    } catch (e) {
      if (mounted) Toast.error(context, 'Couldn\'t update the rate: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      color: YosColors.mint,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.edit_rounded, color: YosColors.ink, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text('Points earn rate',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
              'How much fee earns 1 point on a scan — also what redeeming '
              'a point is worth. Redeem toward fixed ₱'
              '${kRedemptionTiers.join('/₱')} tiers (min ₱${kRedemptionTiers.first}).',
              style: const TextStyle(
                  color: YosColors.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _rate,
                  enabled: !_saving,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onSubmitted: (_) => _save(),
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    prefixText: '₱ ',
                    suffixText: ' = 1 point',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
