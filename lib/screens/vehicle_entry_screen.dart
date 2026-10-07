import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/registry_service.dart';
import '../widgets/visit_flow.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/glow_effects.dart';
import '../widgets/zone_chip_grid.dart';
import 'rfid_scan_screen.dart';

class PlateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var raw = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (raw.length > 8) raw = raw.substring(0, 8);
    return TextEditingValue(
      text: raw,
      selection: TextSelection.collapsed(offset: raw.length),
    );
  }
}

/// Vehicle entry: manual-only — plate/name typed by hand, no camera step.
class VehicleEntryScreen extends StatefulWidget {
  const VehicleEntryScreen({super.key});

  @override
  State<VehicleEntryScreen> createState() => _VehicleEntryScreenState();
}

class _VehicleEntryScreenState extends State<VehicleEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _driver = TextEditingController();
  final _plate = TextEditingController();
  VehicleType _type = VehicleType.car;
  String _zoneId = kZones.first.id;


  @override
  void initState() {
    super.initState();
    FeeSettingsService.instance.addListener(_onFeesChanged);
  }

  void _onFeesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FeeSettingsService.instance.removeListener(_onFeesChanged);
    _driver.dispose();
    _plate.dispose();
    super.dispose();
  }

  Future<void> _submitManual() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.mediumImpact();
    // Already parked (checked in, no time out yet)? Then the sheet opens on
    // TIME OUT; the collector can flip it to TIME IN (see runVisitFlow).
    final open = await YosRepository.instance.openVisitFor(_plate.text);
    if (!mounted) return;
    final done = await runVisitFlow(
      context,
      open: open,
      prepareCheckIn: () async {
        // Not saved yet — just a preview. ReceiptPreviewDrawer commits it
        // (via YosRepository.saveTransaction) once the collector prints.
        final tx = YosRepository.instance.buildTransaction(
          driverName: _driver.text,
          plateNumber: _plate.text,
          type: _type,
          zoneId: _zoneId,
        );
        // A manually-typed plate might still belong to a registered (and
        // RFID-enrolled) vehicle — look it up so the redemption option in
        // the receipt drawer isn't scanner-only.
        final registered = await VehicleRegistry.instance.lookup(_plate.text);
        if (!mounted) return null;
        Toast.success(context,
            '${tx.plateNumber} · ${t('time-in ticket ready', 'handa na ang ticket')}');
        return (tx, registered);
      },
    );
    if (done && mounted) Navigator.of(context).pop();
  }

  /// Opens a searchable picker of registered vehicles for one-tap autofill
  /// — reached via the plate field's list icon, for a collector who'd
  /// rather pick a vehicle they've already registered than retype its
  /// plate/driver every visit. Opt-in only (the field itself always just
  /// opens the keyboard for typing — see the field's own decoration);
  /// closing this without picking anything leaves manual typing as the
  /// fallback, same as before this existed.
  Future<void> _pickRegisteredVehicle() async {
    final picked = await showModalBottomSheet<RegisteredVehicle>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _RegisteredVehiclePicker(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _driver.text = picked.driverName;
      _plate.text = picked.plateNumber;
      _type = VehicleType.fromLabel(picked.vehicleType);
      _zoneId = picked.defaultZoneId;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Manual Entry', 'Manu-manong Entry'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              // Card scanning has its own screen now — this one is only
              // for typing a vehicle in by hand.
              PopIn(
                child: GlassCard(
                  color: YosColors.sage,
                  padding: const EdgeInsets.all(18),
                  onTap: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                          builder: (_) => const RfidScanScreen())),
                  child: Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                        child: const Icon(Icons.contactless_rounded,
                            color: YosColors.inkLight, size: 26),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                            t('Has an RFID card? Scan it instead',
                                'May RFID card? I-scan na lang'),
                            style: TextStyle(
                                color: YosColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 16)),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          color: YosColors.inkLight),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    PopIn(
                      delayMs: 60,
                      child: GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t('Driver Details', 'Detalye ng Driver'),
                                style: TextStyle(
                                    color: YosColors.ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16)),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _driver,
                              textCapitalization: TextCapitalization.words,
                              decoration: InputDecoration(
                                labelText:
                                    t('Driver Full Name', "Buong Pangalan ng Driver"),
                                prefixIcon:
                                    const Icon(Icons.person_outline_rounded),
                              ),
                              validator: (v) =>
                                  (v == null || v.trim().length < 2)
                                      ? t("Enter the driver's name",
                                          'Ilagay ang pangalan ng driver')
                                      : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _plate,
                              inputFormatters: [PlateFormatter()],
                              style: text.titleMedium?.copyWith(
                                  letterSpacing: 3,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ]),
                              // Tapping in always opens the keyboard for
                              // direct typing — the searchable picker is
                              // opt-in only, via the list icon below, not
                              // forced on every tap (see
                              // _pickRegisteredVehicle's own doc comment).
                              decoration: InputDecoration(
                                labelText: t('Plate Number', 'Plaka Numero'),
                                hintText: 'ABC1234',
                                prefixIcon: const Icon(
                                    Icons.confirmation_number_outlined),
                                suffixIcon: IconButton(
                                  tooltip: t('Pick a registered vehicle',
                                      'Pumili ng nakarehistrong sasakyan'),
                                  icon: const Icon(Icons.list_alt_rounded),
                                  onPressed: _pickRegisteredVehicle,
                                ),
                              ),
                              validator: (v) =>
                                  (v == null || v.trim().length < 5)
                                      ? t('Enter a valid plate number',
                                          'Ilagay ang wastong plaka numero')
                                      : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    PopIn(
                      delayMs: 120,
                      child: GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t('Vehicle Type', 'Uri ng Sasakyan'),
                                style: TextStyle(
                                    color: YosColors.ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16)),
                            const SizedBox(height: 12),
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 190,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 2.2,
                              ),
                              itemCount: VehicleType.values.length,
                              itemBuilder: (context, i) => _TypeChip(
                                type: VehicleType.values[i],
                                color: pastelAt(i),
                                selected: VehicleType.values[i] == _type,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _type = VehicleType.values[i]);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    PopIn(
                      delayMs: 180,
                      child: GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t('Zone', 'Zone'),
                                style: TextStyle(
                                    color: YosColors.ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16)),
                            const SizedBox(height: 10),
                            ZoneChipGrid(
                              selectedZoneId: _zoneId,
                              onChanged: (id) => setState(() => _zoneId = id),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                            t(
                                'First ${FeeSettingsService.instance.baseHours} Hours ₱${FeeSettingsService.instance.feeFor(_type).toStringAsFixed(0)} · Then ₱${FeeSettingsService.instance.extraHourFeeFor(_type).toStringAsFixed(0)}/Hours',
                                'Unang ${FeeSettingsService.instance.baseHours} oras ₱${FeeSettingsService.instance.feeFor(_type).toStringAsFixed(0)} · tapos ₱${FeeSettingsService.instance.extraHourFeeFor(_type).toStringAsFixed(0)}/oras'),
                            maxLines: 1,
                            style: text.headlineMedium?.copyWith(fontSize: 22)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _submitManual,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                        side: BorderSide(color: YosColors.ink, width: 1.5),
                        minimumSize: const Size(double.infinity, 0),
                      ),
                      icon: Icon(Icons.receipt_rounded, color: YosColors.ink),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(t('Time In / Time Out', 'Pasok / Labas'),
                            maxLines: 1,
                            style: TextStyle(
                                color: YosColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 15)),
                      ),
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

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.type,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final VehicleType type;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        decoration: BoxDecoration(
          color: selected ? color : YosColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? YosColors.inkLight : YosColors.glassBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(type.icon, size: 22, color: YosColors.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(type.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 13)),
                    Text(
                        '₱${FeeSettingsService.instance.feeFor(type).toStringAsFixed(0)}',
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: YosColors.sub)),
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

/// Searchable list of every registered vehicle, for [_pickRegisteredVehicle]
/// — tapping a row pops this sheet with that vehicle; closing it without
/// tapping one (the X, or dragging it away) pops with nothing, leaving the
/// plate field exactly as it was.
class _RegisteredVehiclePicker extends StatefulWidget {
  const _RegisteredVehiclePicker();

  @override
  State<_RegisteredVehiclePicker> createState() =>
      _RegisteredVehiclePickerState();
}

class _RegisteredVehiclePickerState extends State<_RegisteredVehiclePicker> {
  final _search = TextEditingController();

  // Grabbed once, not called fresh inside build() — see RfidPointsScreen's
  // identical `late final` pattern and its doc comment for why.
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
    super.dispose();
  }

  List<RegisteredVehicle> _filter(List<RegisteredVehicle> list) {
    final q = _search.text.trim().toUpperCase();
    if (q.isEmpty) return list;
    return list
        .where((v) =>
            v.plateNumber.toUpperCase().contains(q) ||
            v.driverName.toUpperCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: YosColors.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                  color: YosColors.sub.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(3)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        t('Registered Vehicles', 'Mga Nakarehistrong Sasakyan'),
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 17)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, color: YosColors.sub),
                    tooltip: t('Close', 'Isara'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _search,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: t('Search plate or driver name',
                      'Maghanap ng plaka o pangalan ng driver'),
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<List<RegisteredVehicle>>(
                stream: _vehicles,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return Center(
                        child:
                            CircularProgressIndicator(color: YosColors.accent));
                  }
                  final list = _filter(snap.data!);
                  if (list.isEmpty) {
                    return Center(
                      child: Text(
                          snap.data!.isEmpty
                              ? t('No registered vehicles yet.',
                                  'Wala pang nakarehistrong sasakyan.')
                              : t('No match found.', 'Walang nahanap.'),
                          style: TextStyle(color: YosColors.sub)),
                    );
                  }
                  return ListView.builder(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final v = list[i];
                      final vt = VehicleType.fromLabel(v.vehicleType);
                      return ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                              color: YosColors.mint,
                              borderRadius: BorderRadius.circular(12)),
                          child: Icon(vt.icon, color: YosColors.ink, size: 20),
                        ),
                        title: Text(v.plateNumber,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2)),
                        subtitle: Text(v.driverName,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.of(context).pop(v),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

