import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/points_settings_service.dart';
import '../services/printer_service.dart';
import '../services/registry_service.dart';
import '../widgets/app_dialog.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/glow_effects.dart';
import '../widgets/vehicle_type_override_dialog.dart';
import '../widgets/zone_chip_grid.dart';

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
  final _rfid = TextEditingController();
  final _rfidFocus = FocusNode();
  VehicleType _type = VehicleType.tricycle;
  String _zoneId = kZones.first.id;

  /// True from the moment a tag resolves to a match until its receipt
  /// sheet closes — blocks a second scan from opening a second sheet (or
  /// double-writing a transaction) while the first one is still being
  /// confirmed/printed. See _onRfidScanned.
  bool _receiptBusy = false;

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
    _rfid.dispose();
    _rfidFocus.dispose();
    super.dispose();
  }

  /// Fires when the RFID field receives an Enter/Return keystroke — a
  /// plug-and-play USB RFID reader enumerates as a USB-HID keyboard and
  /// "types" the tag ID followed by Enter into whichever field has focus,
  /// so a focused text field is all the "connection" this needs (same
  /// pattern as RegisterVehicleScreen._onRfidScanned and
  /// RfidPointsScreen._onScan). An enrolled tag goes straight to the
  /// receipt with that vehicle's own saved details — the whole point of
  /// enrolling a card is never re-typing them at the counter again. An
  /// unrecognized tag just reports that and leaves the manual form below
  /// as the fallback, exactly like a plate the scanner didn't find used to.
  Future<void> _onRfidScanned(String raw) async {
    final tag = raw.trim();
    _rfid.clear();
    if (tag.isEmpty) return;
    if (_receiptBusy) {
      Toast.warn(context,
          t('Finish the current receipt first.', 'Tapusin muna ang kasalukuyang resibo.'));
      return;
    }
    _receiptBusy = true;
    try {
      final match = await VehicleRegistry.instance.lookupByRfid(tag);
      if (!mounted) return;
      if (match == null) {
        Toast.error(context, 'No vehicle enrolled with tag "$tag".');
        _rfidFocus.requestFocus();
        return;
      }
      final registeredType = VehicleType.fromLabel(match.vehicleType);
      final type =
          await confirmVehicleTypeOverride(context, current: registeredType);
      if (!mounted) return;
      if (type == null) {
        _rfidFocus.requestFocus();
        return;
      }
      final tx = YosRepository.instance.buildTransaction(
        driverName: match.driverName,
        plateNumber: match.plateNumber,
        type: type,
        zoneId: match.defaultZoneId,
      );
      HapticFeedback.heavyImpact();
      Toast.success(context,
          '${match.plateNumber} · ${match.driverName} · ₱${tx.fee.toStringAsFixed(0)}');
      await _showReceiptDrawer(tx, registered: match);
    } finally {
      _receiptBusy = false;
    }
  }

  Future<void> _submitManual() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.mediumImpact();
    // Not saved yet — just a preview. ReceiptPreviewDrawer commits it
    // (via YosRepository.saveTransaction) once the collector prints or
    // explicitly saves without printing.
    final tx = YosRepository.instance.buildTransaction(
      driverName: _driver.text,
      plateNumber: _plate.text,
      type: _type,
      zoneId: _zoneId,
    );
    // A manually-typed plate might still belong to a registered (and
    // RFID-enrolled) vehicle — look it up so the redemption option in the
    // receipt drawer isn't scanner-only.
    final registered = await VehicleRegistry.instance.lookup(_plate.text);
    if (!mounted) return;
    Toast.success(context,
        '${tx.plateNumber} · ₱${tx.fee.toStringAsFixed(0)} ready to print');
    _showReceiptDrawer(tx, registered: registered);
  }

  /// Opens a searchable picker of registered vehicles for one-tap autofill
  /// — reached by tapping the plate field while it's empty, for a
  /// collector who'd rather pick a vehicle they've already registered
  /// than retype its plate/driver every visit. Only fires while the field
  /// is empty (see the field's own onTap) so it doesn't keep popping back
  /// up while they're editing what they just typed; closing it without
  /// picking anything leaves manual typing as the fallback, same as
  /// before this existed.
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

  Future<void> _showReceiptDrawer(ParkingTransaction tx,
      {RegisteredVehicle? registered}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReceiptPreviewDrawer(
        tx: tx,
        registered: registered,
        onDone: () {
          Navigator.of(context)
            ..pop()
            ..pop();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('New vehicle', 'Bagong Sasakyan'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              PopIn(
                child: GlassCard(
                  color: YosColors.sage,
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: const BoxDecoration(
                                color: Colors.white, shape: BoxShape.circle),
                            // Fixed, matching the always-white circle — not
                            // the dynamic YosColors.ink, which goes
                            // near-white (and vanishes) in dark mode.
                            child: const Icon(Icons.contactless_rounded,
                                color: YosColors.inkLight, size: 26),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t('Tap RFID card', 'I-tap ang RFID Card'),
                                    style: TextStyle(
                                        color: YosColors.ink,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 17)),
                                Text(
                                    t(
                                        'Enrolled vehicles get a receipt '
                                            'instantly — no retyping',
                                        'Agad na makakakuha ng resibo ang '
                                            'mga naka-enroll na sasakyan — '
                                            'walang muling pagta-type'),
                                    style: TextStyle(
                                        color: YosColors.ink,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // keyboardType.none (not readOnly): suppresses the
                      // on-screen keyboard so there's no manual-typing path,
                      // while still keeping a live platform text-input
                      // connection open — readOnly would drop that
                      // connection entirely, which on Android also blocks a
                      // directly-connected (OTG) HID reader's keystrokes
                      // from ever reaching this field, not just the soft
                      // keyboard.
                      TextField(
                        controller: _rfid,
                        focusNode: _rfidFocus,
                        autofocus: true,
                        showCursor: false,
                        keyboardType: TextInputType.none,
                        textInputAction: TextInputAction.done,
                        onSubmitted: _onRfidScanned,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: YosColors.surface,
                          hintText: 'Waiting for a card…',
                          prefixIcon: const Icon(Icons.nfc_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(t('Or enter manually', 'O Ilagay nang Manu-mano'),
                    style: TextStyle(
                        color: YosColors.sub,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2)),
              ),
              const SizedBox(height: 12),
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
                            Text(t('Driver details', 'Detalye ng Driver'),
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
                                    t('Driver full name', "Buong Pangalan ng Driver"),
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
                              // Only while empty — tapping in to fix a typo
                              // on an already-typed plate shouldn't keep
                              // reopening the picker (see
                              // _pickRegisteredVehicle's own doc comment).
                              onTap: _plate.text.trim().isEmpty
                                  ? _pickRegisteredVehicle
                                  : null,
                              decoration: InputDecoration(
                                labelText: t('Plate number', 'Plaka Numero'),
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
                            Text(t('Vehicle type', 'Uri ng Sasakyan'),
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
                            '${t('Fee', 'Bayad')}  ₱${FeeSettingsService.instance.feeFor(_type).toStringAsFixed(2)}',
                            maxLines: 1,
                            style: text.headlineMedium?.copyWith(fontSize: 26)),
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
                        child: Text(t('Generate receipt', 'Gumawa ng Resibo'),
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
                        t('Registered vehicles', 'Mga Nakarehistrong Sasakyan'),
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

// ------------- Receipt preview -----------------

/// The receipt confirmation/print sheet shown after a transaction is
/// built — from manual entry or an RFID tap, on Vehicle Entry or straight
/// from the Dashboard (see DashboardScreen._onRfidScanned). Public because
/// both screens open it via showModalBottomSheet.
class ReceiptPreviewDrawer extends StatefulWidget {
  const ReceiptPreviewDrawer(
      {super.key,
      required this.tx,
      required this.onDone,
      this.registered,
      this.autoRedeemMax = false,
      this.redeemTier});
  final ParkingTransaction tx;
  final VoidCallback onDone;

  /// The matched (or manually-looked-up) registry entry for this plate, if
  /// any — only vehicles with a non-null [RegisteredVehicle.rfidTag] and a
  /// positive [RegisteredVehicle.points] balance get the redemption option
  /// below.
  final RegisteredVehicle? registered;

  /// Opens the sheet with redemption already maxed out — unused today
  /// (RfidPointsScreen's own points/discount popup now picks a specific
  /// [redeemTier] instead of always maxing out), kept for any future entry
  /// point that wants "just redeem as much as this vehicle qualifies for"
  /// without the collector choosing a tier first.
  final bool autoRedeemMax;

  /// Opens the sheet with this specific peso tier already selected — from
  /// RfidPointsScreen's points/discount popup, where the collector picks
  /// which of the eligible 25/50/75/100% tiers to redeem rather than
  /// always getting the maximum. Every other entry point (an RFID tap at
  /// Vehicle Entry/Dashboard, manual plate entry) leaves this null —
  /// redemption there stays opt-in via the stepper.
  final int? redeemTier;

  @override
  State<ReceiptPreviewDrawer> createState() => _ReceiptPreviewDrawerState();
}

class _ReceiptPreviewDrawerState extends State<ReceiptPreviewDrawer> {
  bool _printing = false;
  bool _saved = false;
  String? _status;

  /// Whether [_status] represents success — tracked separately rather than
  /// sniffing the (now-translatable, see [t]) display text itself, since a
  /// Filipino _status string no longer starts with the English word
  /// "Printed".
  bool _statusOk = false;

  /// The tier actually redeemed — null unless the collector opts in (or
  /// widget.autoRedeemMax/redeemTier picks one — see initState). Driving
  /// state lives here rather than on the peso amount so the flat points
  /// cost (see [redemptionPointsCost]) is never reverse-derived from a
  /// float.
  int? _redeemedTier;

  /// The peso discount actually applied — 0 unless [_redeemedTier] is set.
  double get _redeemedValue =>
      _redeemedTier == null ? 0 : _vehicleFee * _redeemedTier! / 100;

  /// This collector's own phone number, for the receipt footer (see
  /// [_receiptClosingLines]) — fetched once since, unlike their display
  /// name, it isn't cached on the Firebase Auth session itself. Null
  /// until it loads, or if this account has none on file (an older
  /// registration, or the read failing) — the footer just omits the line
  /// rather than falling back to a shared number.
  String? _collectorPhone;

  /// Points redeeming costs — flat per [_redeemedTier] (see
  /// [redemptionPointsCost]), not scaled by fee. 0 while nothing's
  /// redeemed.
  double get _redeemedPointsCost =>
      _redeemedTier == null ? 0 : redemptionPointsCost(_redeemedTier!);

  @override
  void initState() {
    super.initState();
    if (widget.redeemTier != null) {
      _redeemedTier = widget.redeemTier;
    } else if (widget.autoRedeemMax) {
      _redeemedTier = _eligibleTiers.isEmpty ? null : _eligibleTiers.last;
    }
    YosRepository.instance.currentUserPhone().then((phone) {
      if (mounted) setState(() => _collectorPhone = phone);
    });
  }

  /// The points/redemption section shows for any RFID-enrolled vehicle,
  /// including a plain RFID tap at Vehicle Entry/Dashboard — the
  /// collector always gets the choice to redeem a tier or leave it alone
  /// (see [_RedeemPointsCard], which starts with nothing selected unless
  /// [autoRedeemMax]/[redeemTier] pre-picks one from RfidPointsScreen's
  /// popup). Not shown for a vehicle with no RFID tag, which has no
  /// points to show at all.
  bool get _isPointsEnrolled => widget.registered?.rfidTag != null;

  /// This vehicle type's own fee — what each [kRedemptionTiers] percentage
  /// actually discounts against.
  double get _vehicleFee => FeeSettingsService.instance
      .feeFor(VehicleType.fromLabel(widget.tx.vehicleType));

  /// [kRedemptionTiers] the current balance can afford, ascending — each
  /// tier's points cost is flat (see [redemptionPointsCost]), not scaled
  /// by fee.
  List<int> get _eligibleTiers {
    final balance = widget.registered?.points ?? 0;
    return kRedemptionTiers
        .where((t) => redemptionPointsCost(t) <= balance)
        .toList();
  }

  /// The fee actually charged after any redemption — what's confirmed,
  /// printed, and saved, all read from here rather than widget.tx.fee
  /// directly so they can never disagree. [_redeemedValue] is already a
  /// peso amount, so it subtracts straight off the fee.
  double get _effectiveFee =>
      (widget.tx.fee - _redeemedValue).clamp(0, widget.tx.fee);

  /// This collector's own name and contact number, then [kReceiptFooter] —
  /// so a printed receipt shows *this* collector's number, not one shared
  /// business line, and can be traced back to who processed it, with the
  /// thank-you note as the very last thing before "Keep this receipt."
  /// rather than sitting ahead of it. Shared between the printed paper and
  /// the on-screen preview so they never disagree.
  List<String> get _receiptClosingLines => [
        'Collector: ${YosRepository.instance.currentUserName}',
        if (_collectorPhone != null) _collectorPhone!,
        ...kReceiptFooter,
      ];

  /// The points section shown on the receipt (paper and screen alike),
  /// null for a vehicle that isn't RFID-enrolled since it has no points
  /// to show. earned mirrors what VehicleRegistry.touch will actually
  /// credit in [_commit] — a redeemed transaction is pure spend and earns
  /// nothing new, so the receipt never shows a number that doesn't match
  /// what gets recorded.
  ReceiptPoints? get _receiptPoints {
    final reg = widget.registered;
    if (reg?.rfidTag == null) return null;
    final redeemed = _redeemedPointsCost;
    final earned = redeemed > 0
        ? 0.0
        : PointsSettingsService.instance.pointsForFee(_effectiveFee);
    return (
      earned: earned,
      redeemed: redeemed,
      balance: reg!.points - redeemed + earned,
      discountPesos: _redeemedValue,
    );
  }

  /// The one place this transaction actually gets written — on a
  /// successful print, the only way to commit one now. A
  /// generated-but-abandoned receipt (sheet dismissed without printing)
  /// is never saved at all. Guarded by [_saved] against a double-write.
  ///
  /// Points earned/redeemed audit entries (with exact previous/new
  /// balance) are logged inside VehicleRegistry.touch itself, not here —
  /// it's the one place that actually reads the balance fresh right
  /// before writing it, so its before/after values are authoritative in
  /// a way this screen's possibly-stale widget.registered.points isn't.
  void _commit() {
    if (_saved) return;
    _saved = true;
    final fee = _effectiveFee;
    final redeemed = _redeemedPointsCost;
    YosRepository.instance.saveTransaction(
        widget.tx.copyWith(printed: true, fee: fee, discount: _redeemedValue));
    VehicleRegistry.instance
        .touch(widget.tx.plateNumber, fee: fee, redeemedPoints: redeemed);
  }

  /// Asks the collector to confirm cash was actually collected before
  /// this transaction lands in today's collection — a generated receipt
  /// on screen doesn't mean the driver paid. Skipped if [_saved] is
  /// already true (e.g. tapping "Print receipt" again on an entry that
  /// was already confirmed and saved).
  Future<bool> _confirmPayment() async {
    if (_saved) return true;
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('Payment received?', 'Natanggap na ba ang bayad?'),
      message: t(
          'Confirm PHP ${_effectiveFee.toStringAsFixed(2)} has been '
              'collected from the driver before this is logged.',
          'Kumpirmahin na nakolekta na ang PHP ${_effectiveFee.toStringAsFixed(2)} '
              'mula sa driver bago ito i-log.'),
      confirmLabel: t('Yes, received', 'Oo, natanggap na'),
      confirmIcon: Icons.check_rounded,
      confirmColor: YosColors.good,
    );
    return confirmed == true;
  }

  Future<void> _print() async {
    if (!await _confirmPayment()) return;
    if (!mounted) return;
    final printer = PrinterService.instance;
    setState(() {
      _printing = true;
      _status = null;
    });
    try {
      if (!printer.isConnected) {
        setState(() => _status = t(
            'No printer paired. Open Printer settings from the dashboard first.',
            'Walang naka-pair na printer. Buksan ang Printer settings mula sa dashboard.'));
        Toast.warn(context, t('Connect a printer first', 'Mag-connect muna ng printer'));
        return;
      }

      await printer.printParkingTicket(
        trackingId: widget.tx.trackingId,
        driverName: widget.tx.driverName,
        plateNumber: widget.tx.plateNumber,
        vehicleType: widget.tx.vehicleType,
        zoneId: widget.tx.zoneId,
        fee: _effectiveFee,
        timestamp: widget.tx.timestamp,
        header: kReceiptHeader,
        footer: kOrdinanceRef,
        closingLines: _receiptClosingLines,
        points: _receiptPoints,
      );

      _commit();
      HapticFeedback.heavyImpact();
      setState(() {
        _status = t('Printed ✓', 'Naka-print ✓');
        _statusOk = true;
      });
      if (mounted) Toast.success(context, t('Receipt printed', 'Naka-print ang resibo'));
      await Future.delayed(const Duration(milliseconds: 900));
      widget.onDone();
    } catch (e) {
      setState(() {
        _status = '${t('Print failed', 'Nabigo ang pag-print')}: $e';
        _statusOk = false;
      });
      if (mounted) Toast.error(context, t('Print failed', 'Nabigo ang pag-print'));
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: YosColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                    color: YosColors.sub.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(t('Receipt ready!', 'Handa na ang Resibo!'),
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 20)),
            ),
            if (_isPointsEnrolled) ...[
              const SizedBox(height: 16),
              _RedeemPointsCard(
                balance: widget.registered!.points,
                redeemedTier: _redeemedTier,
                vehicleFee: _vehicleFee,
                vehicleType: widget.tx.vehicleType,
                onChanged: _saved
                    ? null
                    : (t) => setState(() => _redeemedTier = t),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
              decoration: BoxDecoration(
                  color: YosColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: kSoftShadow),
              child: Column(
                children: [
                  Image.asset('assets/icon/logo_receipt.png',
                      height: 56, width: 56, fit: BoxFit.contain),
                  const SizedBox(height: 12),
                  // Same text/formatting PrinterService uses for the
                  // printed paper, split around the Driver row: that row
                  // is its own widget below, with "Driver" fixed-size and
                  // only the name shrinking to fit (never wrapping to a
                  // new line, and never truncated) — mirroring how
                  // _buildDriverNameRaster renders the same row for the
                  // physical receipt.
                  Text(
                    PrinterService.instance
                        .previewLinesBeforeDriver(
                          trackingId: tx.trackingId,
                          header: kReceiptHeader,
                        )
                        .join('\n'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: YosColors.ink,
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.8),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('Driver  ',
                          style: TextStyle(
                              color: YosColors.ink,
                              fontFamily: 'monospace',
                              fontSize: 13,
                              height: 1.8)),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(tx.driverName,
                              style: TextStyle(
                                  color: YosColors.ink,
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  height: 1.8)),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    PrinterService.instance
                        .previewLinesAfterDriver(
                          plateNumber: tx.plateNumber,
                          vehicleType: tx.vehicleType,
                          zoneId: tx.zoneId,
                          fee: _effectiveFee,
                          timestamp: tx.timestamp,
                          footer: kOrdinanceRef,
                          closingLines: _receiptClosingLines,
                          points: _receiptPoints,
                        )
                        .join('\n'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: YosColors.ink,
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.8),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_status!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: _statusOk ? YosColors.good : YosColors.bad,
                        fontWeight: FontWeight.w800)),
              ),
            _printing
                ? Center(child: CircularProgressIndicator(color: YosColors.ink))
                : BreathingGlowButton(
                    label: t('Print Receipt', 'I-print ang Resibo'),
                    icon: Icons.print_rounded,
                    onPressed: _print,
                  ),
          ],
        ),
      ),
    );
  }
}

/// Opt-in points redemption, shown only on the receipt reached via
/// RfidPointsScreen's "Redeem points" button, never on a plain RFID tap
/// or manual entry's receipt — see
/// _ReceiptPreviewDrawerState._isPointsEnrolled. Never auto-applies a
/// discount; [redeemedTier] starts null and only moves via tapping a
/// tier. Tiers are percentages of [vehicleFee] (kRedemptionTiers) for
/// display, but each one's points cost is flat (see
/// [redemptionPointsCost]), not scaled by the discount.
class _RedeemPointsCard extends StatelessWidget {
  const _RedeemPointsCard({
    required this.balance,
    required this.redeemedTier,
    required this.vehicleFee,
    required this.vehicleType,
    required this.onChanged,
  });

  final double balance;
  final int? redeemedTier;

  /// This vehicle type's own fee — what each tier percentage discounts
  /// against (e.g. 25% of a ₱100 fee is ₱25 off).
  final double vehicleFee;

  /// Unused by the disabled-tier check now (a percentage can never
  /// exceed the fee it's a share of) — kept as a constructor param since
  /// the caller already has it handy and a future per-vehicle-type
  /// restriction might want it again.
  final String vehicleType;

  /// Null while the sheet is already saved — the tiers freeze once the
  /// transaction has actually been committed.
  final ValueChanged<int?>? onChanged;

  double _discountFor(int tier) => vehicleFee * tier / 100;

  /// Why [tier] can't be selected right now, or null if it can.
  String? _disabledReason(int tier) {
    final cost = redemptionPointsCost(tier);
    if (cost > balance) {
      return t('Needs ${formatPoints(cost - balance)} more points',
          'Kailangan pa ng ${formatPoints(cost - balance)} points');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YosColors.mint,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.loyalty_rounded,
                  color: YosColors.accentDeep, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    t('${formatPoints(balance)} points available',
                        '${formatPoints(balance)} puntos available'),
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tier in kRedemptionTiers)
                Builder(builder: (context) {
                  final reason = _disabledReason(tier);
                  final discount = _discountFor(tier);
                  final chip = ChoiceChip(
                    label: Text(t(
                        '₱${discount.toStringAsFixed(0)} off — Requires '
                            '${formatPoints(redemptionPointsCost(tier))} points',
                        '₱${discount.toStringAsFixed(0)} off — Kailangan ng '
                            '${formatPoints(redemptionPointsCost(tier))} points')),
                    selected: redeemedTier == tier,
                    // Tappable even when unaffordable — rather than a
                    // silently-disabled chip, picking one the balance
                    // can't cover surfaces the Insufficient Points
                    // warning below instead of just doing nothing.
                    onSelected: onChanged == null
                        ? null
                        : (selected) {
                            if (!selected) {
                              onChanged!(null);
                              return;
                            }
                            if (reason != null) {
                              Toast.error(
                                  context, t('Insufficient Points', 'Kulang ang Points'));
                              return;
                            }
                            onChanged!(tier);
                          },
                  );
                  return reason == null
                      ? chip
                      : Opacity(
                          opacity: 0.6,
                          child: Tooltip(message: reason, child: chip),
                        );
                }),
            ],
          ),
          if (redeemedTier != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                  t(
                      '− ₱${_discountFor(redeemedTier!).toStringAsFixed(0)} off this fee',
                      '− ₱${_discountFor(redeemedTier!).toStringAsFixed(0)} bawas sa bayad'),
                  style: TextStyle(
                      color: YosColors.accentDeep,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }
}
