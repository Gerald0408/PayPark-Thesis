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
  late DateTime _timeIn = widget.tx.timestamp;

  /// How many hours the driver wants to park — chosen first, before the
  /// ticket can print. A guide for the driver (expected time out and
  /// estimated fee on the ticket); the real fee comes from the actual
  /// time out.
  int? _hours;
  static const _hourChoices = [1, 2, 3, 4, 5, 6, 8, 12];

  DateTime? get _expectedOut =>
      _hours == null ? null : _timeIn.add(Duration(hours: _hours!));

  double? get _estimate => _hours == null
      ? null
      : FeeSettingsService.instance.quote(_type, _timeIn, _expectedOut!).total;

  List<String> get _planLines => _hours == null
      ? const []
      : PrinterService.instance.planLines(
          hours: _hours!, expectedOut: _expectedOut!, estimate: _estimate!);
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
      baseFee: fees.feeFor(_type),
      baseHours: fees.baseHours,
      extraRate: fees.extraHourFeeFor(_type),
    );
  }

  List<String> get _extraLines => [
        if (_geo != null) 'GPS ${_geo!.short}',
        'Collector: ${YosRepository.instance.currentUserName}',
      ];

  Future<void> _chooseTimeIn() async {
    final picked = await pickVisitTime(context, initial: _timeIn);
    if (picked != null && mounted) setState(() => _timeIn = picked);
  }

  /// Saves the time in — unpaid (fee 0) until time out — and counts the
  /// visit on the vehicle's registry entry.
  void _commit({required bool printed}) {
    if (_saved) return;
    _saved = true;
    final reg = widget.registered;
    YosRepository.instance.saveTransaction(widget.tx.copyWith(
      timestamp: _timeIn,
      fee: 0,
      plannedHours: _hours,
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
        planLines: _planLines,
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

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: YosColors.sub,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            Text(value,
                style: TextStyle(
                    color: YosColors.ink,
                    fontSize: 19,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      );

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
      planLines: _planLines,
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
              onTap: (_busy || _saved) ? null : _chooseTimeIn,
            ),
            const SizedBox(height: 16),
            Text(t('How Many Hours?', 'Ilang Oras?'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: YosColors.ink,
                    fontSize: 19,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final h in _hourChoices)
                  ChoiceChip(
                    label: Text('$h ${t('Hours', 'Oras')}',
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    selected: _hours == h,
                    onSelected: (_busy || _saved)
                        ? null
                        : (_) => setState(() => _hours = h),
                  ),
              ],
            ),
            if (_hours != null) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: YosColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: YosColors.glassBorder),
                ),
                child: Column(
                  children: [
                    _row(t('Expected Time Out', 'Inaasahang Labas'),
                        TimeOfDay.fromDateTime(_expectedOut!).format(context)),
                    _row(t('Estimated Fee', 'Tantiyang Bayad'),
                        '₱${_estimate!.toStringAsFixed(0)}'),
                    Text(
                        t('The actual total is computed at Time Out.',
                            'Ang tunay na kabuuan ay kukuwentahin sa paglabas.'),
                        style: TextStyle(color: YosColors.sub, fontSize: 14)),
                  ],
                ),
              ),
            ],
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
                  // Hours must be chosen first.
                  onPressed: _hours == null
                      ? null
                      : (printerReady ? _print : _saveWithoutPrinting),
                  icon: Icon(printerReady
                      ? Icons.print_rounded
                      : Icons.save_rounded),
                  label: Text(
                      _hours == null
                          ? t('Select Hours First', 'Pumili Muna ng Oras')
                          : printerReady
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
