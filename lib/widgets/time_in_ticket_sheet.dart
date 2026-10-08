import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import '../services/error_log_service.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/location_service.dart';
import '../services/printer_service.dart';
import '../services/registry_service.dart';
import 'toast.dart';
import 'visit_flow.dart';

/// TIME IN — the first tap. Prints a short parking ticket (logo, ticket
/// details, the time in, the rates and the lost-ticket fee) and records
/// the vehicle as parked. Nothing is paid here: the fee is worked out from
/// time in → time out and collected at time out (see the check-out sheet).
class TimeInTicketSheet extends StatefulWidget {
  const TimeInTicketSheet({
    super.key,
    required this.tx,
    required this.onDone,
    this.registered,
    this.canSwitchToTimeOut = false,
  });

  /// Built by YosRepository.buildTransaction; saved (with fee 0, i.e.
  /// unpaid) once the ticket is printed or saved.
  final ParkingTransaction tx;
  final VoidCallback onDone;
  final RegisteredVehicle? registered;

  /// The vehicle is already parked — offer "check it out instead".
  final bool canSwitchToTimeOut;

  @override
  State<TimeInTicketSheet> createState() => _TimeInTicketSheetState();
}

class _TimeInTicketSheetState extends State<TimeInTicketSheet> {
  /// Set automatically when the card was tapped — read-only.
  late final DateTime _timeIn = widget.tx.timestamp;
  GeoTag? _geo;
  bool _busy = false;
  bool _saved = false;

  VehicleType get _type => VehicleType.fromLabel(widget.tx.vehicleType);

  @override
  void initState() {
    super.initState();
    LocationService.instance.current().then((g) {
      if (mounted) setState(() => _geo = g);
    });
  }

  List<String> get _rateLines {
    final fees = FeeSettingsService.instance;
    return PrinterService.instance.rateLines(
      timeIn: _timeIn,
      baseFee: fees.feeFor(_type),
      baseHours: fees.baseHours,
      extraRate: fees.extraHourFeeFor(_type),
    );
  }

  List<String> get _extraLines => [
        if (_geo != null) 'GPS ${_geo!.short}',
        'Collector: ${YosRepository.instance.currentUserName}',
      ];

  /// Saves the time in — unpaid (fee 0) until time out — and counts the
  /// visit on the vehicle's registry entry.
  void _commit({required bool printed}) {
    if (_saved) return;
    _saved = true;
    final reg = widget.registered;
    YosRepository.instance.saveTransaction(widget.tx.copyWith(
      timestamp: _timeIn,
      fee: 0,
      printed: printed,
      rfidTagKey: reg?.rfidTag == null
          ? null
          : RegisteredVehicle.normalize(reg!.rfidTag!),
      geoLat: _geo?.lat,
      geoLng: _geo?.lng,
      geoAccuracy: _geo?.accuracy,
    ));
    VehicleRegistry.instance
        .touch(widget.tx.plateNumber, fee: 0, geo: _geo)
        .catchError((Object e, StackTrace st) =>
            ErrorLogService.instance.record(e, st, where: 'count visit'));
  }

  Future<void> _print() async {
    final printer = PrinterService.instance;
    if (!printer.isConnected) {
      Toast.warn(context,
          t('Connect a printer first', 'Mag-connect muna ng printer'));
      return;
    }
    setState(() => _busy = true);
    try {
      await printer.printTimeInTicket(
        ticketNo: widget.tx.trackingId,
        plateNumber: widget.tx.plateNumber,
        vehicleType: widget.tx.vehicleType,
        driverName: widget.tx.driverName,
        zoneId: widget.tx.zoneId,
        timeIn: _timeIn,
        rateLines: _rateLines,
        lostTicketFee: FeeSettingsService.instance.lostTicketFee,
        header: kReceiptHeader,
        extraLines: _extraLines,
      );
      _commit(printed: true);
      HapticFeedback.heavyImpact();
      if (!mounted) return;
      Toast.success(context, t('Time-in ticket printed', 'Na-print ang ticket'));
      widget.onDone();
    } catch (e, st) {
      ErrorLogService.instance.record(e, st, where: 'print time-in ticket');
      if (mounted) {
        Toast.error(context, t('Print failed', 'Nabigo ang pag-print'));
        setState(() => _busy = false);
      }
    }
  }

  void _saveWithoutPrinting() {
    _commit(printed: false);
    HapticFeedback.heavyImpact();
    Toast.success(context, t('Time In saved', 'Na-save ang time in'));
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;
    final printerReady = PrinterService.instance.isConnected;
    final lines = PrinterService.instance.timeInTicketLines(
      ticketNo: tx.trackingId,
      plateNumber: tx.plateNumber,
      vehicleType: tx.vehicleType,
      driverName: tx.driverName,
      zoneId: tx.zoneId,
      timeIn: _timeIn,
      rateLines: _rateLines,
      lostTicketFee: FeeSettingsService.instance.lostTicketFee,
      header: kReceiptHeader,
      extraLines: _extraLines,
    );
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: YosColors.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
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
            const SizedBox(height: 10),
            Text(t('TIME IN', 'PASOK'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: YosColors.ink,
                    fontSize: 24,
                    fontWeight: FontWeight.w900)),
            Text(
                t('Nothing to pay now — the fee is computed at Time Out.',
                    'Walang babayaran ngayon — kukuwentahin ang bayad sa paglabas.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: YosColors.sub, fontSize: 15)),
            const SizedBox(height: 14),
            TimeChoiceButton(
              label: t('TIME IN', 'PASOK'),
              icon: Icons.login_rounded,
              time: _timeIn,
              highlight: true,
              onTap: null,
            ),
            if (widget.canSwitchToTimeOut)
              TextButton.icon(
                onPressed: (_busy || _saved)
                    ? null
                    : () => Navigator.of(context).pop(kSwitchVisitMode),
                icon: const Icon(Icons.logout_rounded),
                label: Text(t('This vehicle is parked — TIME OUT instead',
                    'Nakaparada ang sasakyang ito — LABAS na lang')),
              ),
            const SizedBox(height: 16),
            // The ticket exactly as it prints (the paper adds the logo raster
            // and prints the time larger).
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
              decoration: BoxDecoration(
                  color: YosColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: kSoftShadow),
              child: Column(
                children: [
                  Image.asset('assets/icon/logo_receipt.png',
                      height: 56, width: 56, fit: BoxFit.contain),
                  const SizedBox(height: 10),
                  Text(lines.join('\n'),
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
                child: FilledButton.icon(
                  onPressed: printerReady ? _print : _saveWithoutPrinting,
                  icon: Icon(printerReady
                      ? Icons.print_rounded
                      : Icons.save_rounded),
                  label: Text(
                      printerReady
                          ? t('Print Time-In Ticket', 'I-print ang Ticket')
                          : t('Save Time In (no printer)',
                              'I-save ang Time In (walang printer)'),
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
