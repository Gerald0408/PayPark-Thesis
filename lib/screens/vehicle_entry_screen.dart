import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/points_settings_service.dart';
import '../services/printer_service.dart';
import '../services/registry_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/glow_effects.dart';

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
      Toast.warn(context, 'Finish the current receipt first.');
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
      final type = VehicleType.fromLabel(match.vehicleType);
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
        title: const Text('New vehicle',
            style: TextStyle(fontWeight: FontWeight.w800)),
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
                            child: const Icon(Icons.contactless_rounded,
                                color: YosColors.ink, size: 26),
                          ),
                          const SizedBox(width: 14),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Tap RFID card',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 17)),
                                Text(
                                    'Enrolled vehicles get a receipt '
                                    'instantly — no retyping',
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
                        decoration: const InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          hintText: 'Waiting for a card…',
                          prefixIcon: Icon(Icons.nfc_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Center(
                child: Text('Or enter manually',
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
                                const Text('Driver details',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16)),
                                const SizedBox(height: 14),
                                TextFormField(
                                  controller: _driver,
                                  textCapitalization:
                                      TextCapitalization.words,
                                  decoration: const InputDecoration(
                                    labelText: 'Driver full name',
                                    prefixIcon:
                                        Icon(Icons.person_outline_rounded),
                                  ),
                                  validator: (v) =>
                                      (v == null || v.trim().length < 2)
                                          ? 'Enter the driver\'s name'
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
                                  decoration: const InputDecoration(
                                    labelText: 'Plate number',
                                    hintText: 'ABC1234',
                                    prefixIcon: Icon(
                                        Icons.confirmation_number_outlined),
                                  ),
                                  validator: (v) =>
                                      (v == null || v.trim().length < 5)
                                          ? 'Enter a valid plate number'
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
                                const Text('Vehicle type',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16)),
                                const SizedBox(height: 12),
                                GridView.builder(
                                  shrinkWrap: true,
                                  physics:
                                      const NeverScrollableScrollPhysics(),
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
                                      setState(() =>
                                          _type = VehicleType.values[i]);
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
                                const Text('Zone',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16)),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final z in kZones)
                                      ChoiceChip(
                                        label: Text(z.name),
                                        selected: z.id == _zoneId,
                                        selectedColor: YosColors.sage,
                                        onSelected: (_) =>
                                            setState(() => _zoneId = z.id),
                                      ),
                                  ],
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
                                'Fee  ₱${FeeSettingsService.instance.feeFor(_type).toStringAsFixed(2)}',
                                maxLines: 1,
                                style: text.headlineMedium
                                    ?.copyWith(fontSize: 26)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _submitManual,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999)),
                            side: const BorderSide(
                                color: YosColors.ink, width: 1.5),
                            minimumSize: const Size(double.infinity, 0),
                          ),
                          icon: const Icon(Icons.receipt_rounded,
                              color: YosColors.ink),
                          label: const Text('Generate receipt',
                              style: TextStyle(
                                  color: YosColors.ink,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15)),
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
          color: selected ? color : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? YosColors.ink : const Color(0x14000000),
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
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 13)),
                    Text(
                        '₱${FeeSettingsService.instance.feeFor(type).toStringAsFixed(0)}',
                        maxLines: 1,
                        style: const TextStyle(
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
      this.autoRedeemMax = false});
  final ParkingTransaction tx;
  final VoidCallback onDone;

  /// The matched (or manually-looked-up) registry entry for this plate, if
  /// any — only vehicles with a non-null [RegisteredVehicle.rfidTag] and a
  /// positive [RegisteredVehicle.points] balance get the redemption option
  /// below.
  final RegisteredVehicle? registered;

  /// Opens the sheet with redemption already maxed out, for the "Redeem"
  /// button on RfidPointsScreen — that entry point is specifically for a
  /// vehicle that already qualifies for a full-fee redemption, so there's
  /// no reason to make the collector tap the stepper up manually. Every
  /// other entry point (an RFID tap at Vehicle Entry, manual plate entry)
  /// leaves this false — redemption there stays opt-in via the stepper.
  final bool autoRedeemMax;

  @override
  State<ReceiptPreviewDrawer> createState() => _ReceiptPreviewDrawerState();
}

class _ReceiptPreviewDrawerState extends State<ReceiptPreviewDrawer> {
  bool _printing = false;
  bool _saved = false;
  String? _status;

  /// The peso value of the tier the collector chose to redeem against
  /// this fee — 0 unless they opt in, never auto-applied (except
  /// widget.autoRedeemMax — see initState). Always 0 or one of
  /// kRedemptionTiers. Stored as pesos, not points: how many points that
  /// actually costs depends on the live, admin-editable earn rate (see
  /// [_redeemedPointsCost]), so pesos is the one number that stays fixed
  /// regardless of that rate changing mid-transaction.
  double _redeemedValue = 0;

  /// This collector's own phone number, for the receipt footer (see
  /// [_receiptClosingLines]) — fetched once since, unlike their display
  /// name, it isn't cached on the Firebase Auth session itself. Null
  /// until it loads, or if this account has none on file (an older
  /// registration, or the read failing) — the footer just omits the line
  /// rather than falling back to a shared number.
  String? _collectorPhone;

  /// Points [_redeemedValue] actually costs at the current earn rate —
  /// redemption and earning deliberately share one rate rather than
  /// keeping two in sync (see kRedemptionTiers' doc).
  double get _redeemedPointsCost =>
      _redeemedValue / PointsSettingsService.instance.pesoPerPoint;

  @override
  void initState() {
    super.initState();
    if (widget.autoRedeemMax) {
      _redeemedValue =
          _eligibleTiers.isEmpty ? 0 : _eligibleTiers.last.toDouble();
    }
    YosRepository.instance.currentUserPhone().then((phone) {
      if (mounted) setState(() => _collectorPhone = phone);
    });
  }

  /// The points/redemption section only shows on the receipt reached via
  /// RfidPointsScreen's "Redeem points" button (see [autoRedeemMax]) —
  /// that's a deliberate, opt-in redemption action, unlike a plain RFID
  /// tap at Vehicle Entry/Dashboard or manual entry, which are just
  /// "log and print" and shouldn't surface the points balance at all.
  bool get _isPointsEnrolled =>
      widget.registered?.rfidTag != null && widget.autoRedeemMax;

  /// This vehicle type's own fee — the ceiling on what it can ever
  /// redeem toward, regardless of balance. A ₱50 tricycle fee never
  /// unlocks the ₱150/₱200 tiers meant for bigger vehicles, no matter
  /// how many points it's banked.
  double get _vehicleFee => FeeSettingsService.instance
      .feeFor(VehicleType.fromLabel(widget.tx.vehicleType));

  /// [kRedemptionTiers] (peso values) both the current balance — once
  /// converted to points at the live earn rate — and this vehicle type's
  /// own fee (see [_vehicleFee]) allow, ascending. Empty if either rules
  /// out even the lowest tier.
  List<int> get _eligibleTiers {
    final balance = widget.registered?.points ?? 0;
    final rate = PointsSettingsService.instance.pesoPerPoint;
    return kRedemptionTiers
        .where((v) => (v / rate) <= balance && v <= _vehicleFee)
        .toList();
  }

  /// The fee actually charged after any redemption — what's confirmed,
  /// printed, and saved, all read from here rather than widget.tx.fee
  /// directly so they can never disagree. [_redeemedValue] is already a
  /// peso amount, so it subtracts straight off the fee.
  double get _effectiveFee =>
      (widget.tx.fee - _redeemedValue).clamp(0, widget.tx.fee);

  /// [kReceiptFooter] plus this collector's own contact number and name —
  /// so a printed receipt shows *this* collector's number, not one shared
  /// business line, and can be traced back to who processed it. Shared
  /// between the printed paper and the on-screen preview so they never
  /// disagree.
  List<String> get _receiptClosingLines => [
        ...kReceiptFooter,
        if (_collectorPhone != null) _collectorPhone!,
        'Collector: ${YosRepository.instance.currentUserName}',
      ];

  /// The points section shown on the receipt (paper and screen alike),
  /// null for a vehicle that isn't RFID-enrolled since it has no points
  /// to show. earned mirrors what VehicleRegistry.touch will actually
  /// credit in [_commit] — same formula (pointsForFee on the effective,
  /// post-redemption fee) — so the receipt never shows a number that
  /// doesn't match what gets recorded.
  ReceiptPoints? get _receiptPoints {
    final reg = widget.registered;
    if (reg?.rfidTag == null) return null;
    final earned = PointsSettingsService.instance.pointsForFee(_effectiveFee);
    final redeemed = _redeemedPointsCost;
    return (
      earned: earned,
      redeemed: redeemed,
      balance: reg!.points - redeemed + earned,
    );
  }

  /// The one place this transaction actually gets written — on a
  /// successful print, or on an explicit "save without printing". A
  /// generated-but-abandoned receipt (sheet dismissed without either)
  /// is never saved at all. Guarded by [_saved] so the 900ms delay
  /// between a successful print and the sheet closing can't let a
  /// stray tap on "Save without printing" double-write it.
  ///
  /// Points earned/redeemed audit entries (with exact previous/new
  /// balance) are logged inside VehicleRegistry.touch itself, not here —
  /// it's the one place that actually reads the balance fresh right
  /// before writing it, so its before/after values are authoritative in
  /// a way this screen's possibly-stale widget.registered.points isn't.
  void _commit({required bool printed}) {
    if (_saved) return;
    _saved = true;
    final fee = _effectiveFee;
    final redeemed = _redeemedPointsCost;
    YosRepository.instance
        .saveTransaction(widget.tx.copyWith(printed: printed, fee: fee));
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Payment received?'),
        content: Text(
            'Confirm PHP ${_effectiveFee.toStringAsFixed(2)} has been '
            'collected from the driver before this is logged.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not yet'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes, received',
                style: TextStyle(
                    color: YosColors.good, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _saveWithoutPrinting() async {
    if (!await _confirmPayment()) return;
    _commit(printed: false);
    widget.onDone();
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
        setState(() => _status =
            'No printer paired. Open Printer settings from the dashboard first.');
        Toast.warn(context, 'Connect a printer first');
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

      _commit(printed: true);
      HapticFeedback.heavyImpact();
      setState(() => _status = 'Printed ✓');
      if (mounted) Toast.success(context, 'Receipt printed');
      await Future.delayed(const Duration(milliseconds: 900));
      widget.onDone();
    } catch (e) {
      setState(() => _status = 'Print failed: $e');
      if (mounted) Toast.error(context, 'Print failed');
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
        decoration: const BoxDecoration(
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
            const Center(
              child: Text('Receipt ready!',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
            ),
            if (_isPointsEnrolled) ...[
              const SizedBox(height: 16),
              _RedeemPointsCard(
                balance: widget.registered!.points,
                redeemedValue: _redeemedValue,
                vehicleFee: _vehicleFee,
                vehicleType: widget.tx.vehicleType,
                pesoPerPoint: PointsSettingsService.instance.pesoPerPoint,
                onChanged: _saved
                    ? null
                    : (v) => setState(() => _redeemedValue = v),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
              decoration: BoxDecoration(
                  color: Colors.white,
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
                    style: const TextStyle(
                        color: YosColors.ink,
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.8),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text('Driver  ',
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
                              style: const TextStyle(
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
                    style: const TextStyle(
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
                        color: _status!.startsWith('Printed')
                            ? YosColors.good
                            : YosColors.bad,
                        fontWeight: FontWeight.w800)),
              ),
            _printing
                ? const Center(
                    child: CircularProgressIndicator(color: YosColors.ink))
                : BreathingGlowButton(
                    label: 'Print receipt',
                    icon: Icons.print_rounded,
                    onPressed: _print,
                  ),
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: _saveWithoutPrinting,
                child: const Text('Save without printing',
                    style: TextStyle(
                        color: YosColors.sub, fontWeight: FontWeight.w700)),
              ),
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
/// discount; [redeemedValue] starts at 0 and only moves via tapping a
/// tier. Tiers are fixed peso amounts (kRedemptionTiers); what each one
/// actually costs in points depends on [pesoPerPoint], the live earn
/// rate shared with redemption.
class _RedeemPointsCard extends StatelessWidget {
  const _RedeemPointsCard({
    required this.balance,
    required this.redeemedValue,
    required this.vehicleFee,
    required this.vehicleType,
    required this.pesoPerPoint,
    required this.onChanged,
  });

  final double balance;
  final double redeemedValue;

  /// This vehicle type's own fee — a tier above it is disabled as "not
  /// applicable to this vehicle type" even if the balance could
  /// otherwise afford it.
  final double vehicleFee;

  /// Just for the disabled-tier tooltip text (e.g. "Not applicable to
  /// Tricycle parking").
  final String vehicleType;

  /// Pesos one point is worth right now — the same live, admin-editable
  /// rate points are earned at. What a tier's peso value converts to in
  /// points cost.
  final double pesoPerPoint;

  /// Null while the sheet is already saved — the tiers freeze once the
  /// transaction has actually been committed.
  final ValueChanged<double>? onChanged;

  double _pointsCost(int tier) => tier / pesoPerPoint;

  /// Why [tier] can't be selected right now, or null if it can — a tier
  /// above this vehicle's own fee is rejected before an insufficient
  /// balance ever gets checked, since no amount of points changes that.
  String? _disabledReason(int tier) {
    if (tier > vehicleFee) return 'Not applicable to $vehicleType parking';
    final cost = _pointsCost(tier);
    if (cost > balance) {
      return 'Needs ${formatPoints(cost - balance)} more points';
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
              const Icon(Icons.loyalty_rounded,
                  color: YosColors.accentDeep, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${formatPoints(balance)} points available',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14)),
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
                  final chip = ChoiceChip(
                    label: Text('₱$tier · ${formatPoints(_pointsCost(tier))} pts'),
                    selected: redeemedValue == tier,
                    onSelected: onChanged == null || reason != null
                        ? null
                        : (selected) =>
                            onChanged!(selected ? tier.toDouble() : 0),
                  );
                  return reason == null
                      ? chip
                      : Tooltip(message: reason, child: chip);
                }),
            ],
          ),
          if (redeemedValue > 0) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                  '− ₱${redeemedValue.toStringAsFixed(0)} off this fee',
                  style: const TextStyle(
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
