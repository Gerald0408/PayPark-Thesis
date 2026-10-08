import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/parking_fee.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import '../services/error_log_service.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/location_service.dart';
import '../services/points_settings_service.dart';
import '../services/printer_service.dart';
import '../services/registry_service.dart';
import 'app_dialog.dart';
import 'payment_method_picker.dart';
import 'redeem_points_card.dart';
import 'toast.dart';
import 'visit_flow.dart';

/// How the time-out sheet closed.
enum CheckOutOutcome {
  /// Timed out and paid.
  done,
  cancelled,

  /// The collector chose to start a new TIME IN instead — see
  /// runVisitFlow.
  switchMode,
}

/// Opens the TIME OUT sheet for a vehicle that's still parked ([tx] is its
/// time-in). [canSwitchToTimeIn] offers "start a new TIME IN instead"
/// (only runVisitFlow handles that outcome); [redeemTier] pre-selects a
/// points discount (RFID Points' redeem button).
Future<CheckOutOutcome> showCheckOutSheet(
  BuildContext context,
  ParkingTransaction tx, {
  bool canSwitchToTimeIn = false,
  int? redeemTier,
}) async {
  final result = await showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CheckOutSheet(
        tx: tx, canSwitchToTimeIn: canSwitchToTimeIn, redeemTier: redeemTier),
  );
  if (result == kSwitchVisitMode) return CheckOutOutcome.switchMode;
  return result == true ? CheckOutOutcome.done : CheckOutOutcome.cancelled;
}

/// What a visit's time-out receipt shows — shared by the paper
/// ([printCheckOutReceipt]) and the on-screen preview so they never
/// disagree. [tx] is the visit as checked out (or as it will be).
TimeOutReceipt checkOutReceipt(ParkingTransaction tx,
    {bool reprint = false, ReceiptPoints? points}) {
  final baseHours = FeeSettingsService.instance.baseHours;
  final rate = tx.extraHours > 0 ? tx.extraFee / tx.extraHours : 0.0;
  final hours = tx.extraHours == 1 ? 'Hour' : 'Hours';
  return TimeOutReceipt(
    letterhead: kReceiptLetterhead,
    ordinance: kOrdinanceRef,
    trackingId: tx.trackingId,
    timeIn: tx.timestamp,
    timeOut: tx.timeOut ?? tx.timestamp,
    plateNumber: tx.plateNumber,
    driverName: tx.driverName,
    vehicleType: tx.vehicleType,
    zoneId: tx.zoneId,
    breakdown: [
      ('First $baseHours Hours', tx.fee + tx.discount),
      if (tx.extraFee > 0)
        ('Extra ${tx.extraHours} $hours x ${rate.toStringAsFixed(0)}',
            tx.extraFee),
      if (tx.lostTicketFee > 0) ('Lost Ticket', tx.lostTicketFee),
      if (tx.discount > 0) ('Points Discount', -tx.discount),
    ],
    totalPaid: tx.totalPaid,
    paymentMethod:
        PaymentMethod.label(tx.extraPaymentMethod ?? tx.paymentMethod),
    paymentRef: tx.extraPaymentRef ?? tx.paymentRef,
    collectorName: tx.collectorName,
    timedOutBy: tx.checkedOutByName != null &&
            tx.checkedOutByName != tx.collectorName
        ? tx.checkedOutByName
        : null,
    points: points,
    reprint: reprint,
  );
}

/// Prints the full time-out receipt for a checked-out [tx] in the
/// barangay letterhead layout: every detail, time in → time out, the
/// price breakdown and the total paid. Also used to reprint one.
/// [points] is the RFID points earned/redeemed and the balance after
/// (null for a vehicle without a card, or a reprint).
Future<void> printCheckOutReceipt(ParkingTransaction tx,
        {bool reprint = false, ReceiptPoints? points}) =>
    PrinterService.instance.printTimeOutReceipt(
        checkOutReceipt(tx, reprint: reprint, points: points));

class _CheckOutSheet extends StatefulWidget {
  const _CheckOutSheet(
      {required this.tx, required this.canSwitchToTimeIn, this.redeemTier});
  final ParkingTransaction tx;
  final bool canSwitchToTimeIn;
  final int? redeemTier;

  @override
  State<_CheckOutSheet> createState() => _CheckOutSheetState();
}

class _CheckOutSheetState extends State<_CheckOutSheet> {
  bool _busy = false;
  late final Timer _tick;
  String _method = PaymentMethod.cash;
  final _ref = TextEditingController();
  bool _lostTicket = false;
  late int? _redeemTier = widget.redeemTier;

  /// Registry entry, for points — null until loaded / when unregistered.
  RegisteredVehicle? _vehicle;
  GeoTag? _geo;

  /// TIME OUT is the clock: set automatically when the card is tapped,
  /// kept current while the sheet is open, and fixed when payment is
  /// confirmed. It can't be edited.
  DateTime _timeOut = DateTime.now();

  ParkingTransaction get tx => widget.tx;
  VehicleType get _type => VehicleType.fromLabel(tx.vehicleType);

  /// A visit from before time-in tickets: its base fee was paid at check-in.
  bool get _prepaid => tx.fee > 0;

  bool get _canRedeem => !_prepaid && _vehicle?.rfidTag != null;

  double get _discount => (_canRedeem && _redeemTier != null)
      ? FeeSettingsService.instance.feeFor(_type) * _redeemTier! / 100
      : 0;

  double get _redeemedPoints => (_canRedeem && _redeemTier != null)
      ? redemptionPointsCost(_redeemTier!)
      : 0;

  ParkingFee get _price => FeeSettingsService.instance.quote(
        _type,
        tx.timestamp,
        _timeOut,
        lostTicket: _lostTicket,
        discount: _discount,
      );

  /// The visit as it will be saved — what the receipt preview shows.
  /// Mirrors YosRepository.checkOut.
  ParkingTransaction _projected(ParkingFee p) {
    final ref = _method == PaymentMethod.cash ? null : _ref.text.trim();
    final extra = _prepaid
        ? (p.total - tx.fee - p.lostTicketFee).clamp(0, double.infinity).toDouble()
        : p.extraFee;
    return tx.copyWith(
      timeOut: _timeOut,
      checkedOutByName: YosRepository.instance.currentUserName,
      fee: _prepaid ? tx.fee : (p.baseFee - p.discount).clamp(0, p.baseFee).toDouble(),
      discount: _prepaid ? tx.discount : p.discount,
      paymentMethod: _prepaid ? tx.paymentMethod : _method,
      paymentRef: _prepaid ? tx.paymentRef : ref,
      extraHours: extra > 0 ? p.extraHours : 0,
      extraFee: extra,
      extraPaymentMethod: extra > 0 ? _method : null,
      extraPaymentRef: extra > 0 ? ref : null,
      lostTicketFee: p.lostTicketFee,
    );
  }

  /// What's collected now: the whole visit, or for a prepaid visit only
  /// the part not already paid.
  double _dueNow(ParkingTransaction projected) =>
      projected.totalPaid - (_prepaid ? tx.fee : 0);

  ReceiptPoints? _points(ParkingTransaction projected) {
    final v = _vehicle;
    if (v == null || v.rfidTag == null) return null;
    final paid = _dueNow(projected);
    final redeemed = _redeemedPoints;
    final earned =
        redeemed > 0 ? 0.0 : PointsSettingsService.instance.pointsForFee(paid);
    return (
      earned: earned,
      redeemed: redeemed,
      balance: v.points + earned - redeemed,
      discountPesos: projected.discount,
    );
  }

  @override
  void initState() {
    super.initState();
    VehicleRegistry.instance.lookup(tx.plateNumber).then((v) {
      if (mounted) setState(() => _vehicle = v);
    }).catchError((_) {});
    LocationService.instance.current().then((g) => _geo = g);
    // Keeps the time out and the price current while the sheet is open.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_busy) {
        setState(() => _timeOut = DateTime.now());
      }
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    _ref.dispose();
    super.dispose();
  }

  Future<bool> _confirmPaid(double due) async {
    if (due <= 0) return true;
    final amount = 'PHP ${due.toStringAsFixed(2)}';
    final label = PaymentMethod.label(_method);
    if (_method != PaymentMethod.cash && _ref.text.trim().length < 4) {
      Toast.warn(
          context,
          t('Enter the $label reference number first.',
              'Ilagay muna ang reference number ng $label.'));
      return false;
    }
    final ok = await showAppConfirmDialog(
      context,
      title: t('Payment received?', 'Natanggap na ba ang bayad?'),
      message: _method == PaymentMethod.cash
          ? t('Confirm $amount cash has been collected from the driver.',
              'Kumpirmahin na nakolekta na ang $amount na cash mula sa driver.')
          : t("Confirm the driver's $label screen shows $amount sent, reference ${_ref.text.trim()}.",
              'Kumpirmahin na ipinapakita ng $label ng driver na naipadala ang $amount, reference ${_ref.text.trim()}.'),
      confirmLabel: t('Yes, received', 'Oo, natanggap na'),
      confirmIcon: Icons.check_rounded,
      confirmColor: YosColors.good,
    );
    return ok == true;
  }

  Future<void> _checkOut({required bool print}) async {
    _timeOut = DateTime.now();
    // Fixed at the moment of confirming, so what's confirmed is what's
    // recorded even if the clock ticks into another hour meanwhile.
    final price = _price;
    final projected = _projected(price);
    final due = _dueNow(projected);
    if (!await _confirmPaid(due)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final out = YosRepository.instance.checkOut(
      tx,
      price: price,
      paymentMethod: _method,
      paymentRef: _method == PaymentMethod.cash ? null : _ref.text.trim(),
      timeOut: _timeOut,
    );
    HapticFeedback.heavyImpact();
    final points = _points(projected);
    if (_vehicle?.rfidTag != null) {
      VehicleRegistry.instance
          .settleVisitPoints(out.plateNumber,
              paid: due, redeemedPoints: _redeemedPoints, geo: _geo)
          .catchError((Object e, StackTrace st) {
        ErrorLogService.instance.record(e, st, where: 'settle points');
        return null;
      });
    }
    if (print) {
      try {
        await printCheckOutReceipt(out, points: points);
      } catch (e, st) {
        ErrorLogService.instance.record(e, st, where: 'print time-out receipt');
        if (mounted) {
          Toast.error(
              context,
              t('Saved, but printing failed. Reprint it from Transaction Logs.',
                  'Na-save, pero nabigo ang pag-print. I-reprint mula sa Transaction Logs.'));
          Navigator.of(context).pop(true);
        }
        return;
      }
    }
    if (!mounted) return;
    Toast.success(
        context,
        t('${out.plateNumber} timed out · ${formatStay(out.stayDuration)} · ₱${due.toStringAsFixed(0)}',
            'Lumabas ang ${out.plateNumber} · ${formatStay(out.stayDuration)} · ₱${due.toStringAsFixed(0)}'));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final price = _price;
    final projected = _projected(price);
    final due = _dueNow(projected);
    final points = _points(projected);
    final printerReady = PrinterService.instance.isConnected;
    final fees = FeeSettingsService.instance;
    final printer = PrinterService.instance;

    Widget row(String label, String value,
            {bool big = false, Color? color}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: big ? YosColors.ink : YosColors.sub,
                        fontSize: big ? 19 : 16,
                        fontWeight: big ? FontWeight.w800 : FontWeight.w600)),
              ),
              Text(value,
                  style: TextStyle(
                      color: color ?? YosColors.ink,
                      fontSize: big ? 26 : 17,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        );

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => Container(
          decoration: BoxDecoration(
            color: YosColors.bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
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
              const SizedBox(height: 10),
              Text(t('TIME OUT', 'LABAS'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: YosColors.ink,
                      fontSize: 24,
                      fontWeight: FontWeight.w900)),
              Text('${tx.plateNumber} · ${tx.driverName}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: YosColors.sub, fontSize: 17)),
              const SizedBox(height: 14),
              // Both times are automatic (the card taps) and read-only.
              Row(
                children: [
                  Expanded(
                    child: TimeChoiceButton(
                      label: t('TIME IN', 'PASOK'),
                      icon: Icons.login_rounded,
                      time: tx.timestamp,
                      onTap: null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TimeChoiceButton(
                      label: t('TIME OUT', 'LABAS'),
                      icon: Icons.logout_rounded,
                      time: _timeOut,
                      highlight: true,
                      onTap: null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // The price, step by step.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: YosColors.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: YosColors.glassBorder),
                ),
                child: Column(
                  children: [
                    row(t('Total Time', 'Kabuuang oras'),
                        formatStay(price.stay)),
                    row(t('First ${price.baseHours} Hours', 'Unang ${price.baseHours} oras'),
                        '₱${price.baseFee.toStringAsFixed(0)}'),
                    if (price.extraHours > 0)
                      row(
                          t('Extra ${price.extraHours} Hours × ₱${price.extraRate.toStringAsFixed(0)}',
                              'Dagdag ${price.extraHours} oras × ₱${price.extraRate.toStringAsFixed(0)}'),
                          '₱${price.extraFee.toStringAsFixed(0)}'),
                    if (price.lostTicketFee > 0)
                      row(t('Lost Ticket', 'Nawalang Ticket'),
                          '₱${price.lostTicketFee.toStringAsFixed(0)}',
                          color: YosColors.bad),
                    if (price.discount > 0)
                      row(t('Points Discount', 'Diskwento sa points'),
                          '-₱${price.discount.toStringAsFixed(0)}',
                          color: YosColors.good),
                    if (_prepaid)
                      row(t('Already paid at Time In', 'Nabayaran na sa pagpasok'),
                          '-₱${tx.fee.toStringAsFixed(0)}',
                          color: YosColors.good),
                    const Divider(height: 16),
                    row(t('PAY NOW', 'BAYARAN NGAYON'),
                        '₱${due.toStringAsFixed(0)}',
                        big: true),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _lostTicket,
                onChanged: _busy ? null : (v) => setState(() => _lostTicket = v),
                title: Text(
                    t('Lost Ticket (+₱${fees.lostTicketFee.toStringAsFixed(0)})',
                        'Nawalang ticket (+₱${fees.lostTicketFee.toStringAsFixed(0)})'),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              if (_canRedeem) ...[
                const SizedBox(height: 6),
                RedeemPointsCard(
                  balance: _vehicle!.points,
                  redeemedTier: _redeemTier,
                  vehicleFee: fees.feeFor(_type),
                  vehicleType: tx.vehicleType,
                  onChanged:
                      _busy ? null : (t) => setState(() => _redeemTier = t),
                ),
              ],
              if (due > 0) ...[
                const SizedBox(height: 16),
                PaymentMethodPicker(
                  method: _method,
                  refController: _ref,
                  onChanged: _busy ? null : (m) => setState(() => _method = m),
                  onRefChanged: () => setState(() {}),
                ),
              ],
              const SizedBox(height: 18),
              // The full receipt exactly as it will print.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
                decoration: BoxDecoration(
                    color: YosColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: kSoftShadow),
                child: Column(
                  children: [
                    Image.asset('assets/icon/logo_receipt.png',
                        height: 56, width: 56, fit: BoxFit.contain),
                    const SizedBox(height: 10),
                    // Exactly the lines the paper prints.
                    Text(
                        printer
                            .timeOutReceiptLines(
                                checkOutReceipt(projected, points: points))
                            .join('\n'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.7)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_busy)
                const Center(child: CircularProgressIndicator())
              else ...[
                SizedBox(
                  height: 58,
                  child: FilledButton(
                    onPressed: () => _checkOut(print: printerReady),
                    child: Text(
                        printerReady
                            ? t('Collect ₱${due.toStringAsFixed(0)} & print receipt',
                                'Singilin ₱${due.toStringAsFixed(0)} at i-print')
                            : t('Collect ₱${due.toStringAsFixed(0)}',
                                'Singilin ₱${due.toStringAsFixed(0)}'),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ),
                if (widget.canSwitchToTimeIn)
                  Center(
                    child: TextButton(
                      onPressed: () =>
                          Navigator.of(context).pop(kSwitchVisitMode),
                      child: Text(
                          t('Not leaving? Start a new TIME IN instead',
                              'Hindi aalis? Bagong PASOK na lang'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(t('Cancel', 'Kanselahin'),
                      style: const TextStyle(fontSize: 16)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
