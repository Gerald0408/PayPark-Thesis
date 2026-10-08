import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/fee_settings_service.dart';
import '../services/locale_controller.dart';
import '../services/printer_service.dart';
import '../widgets/check_out_sheet.dart';
import '../widgets/toast.dart';
import '../widgets/visit_flow.dart';

/// TEMPORARY test tool (see dev_flags.dart): simulate a time-in tap and a
/// time-out tap at any times — e.g. 8:00 AM → 9:00 AM — and see the price
/// the system computes plus exactly what both printouts say, using the
/// live Fee Matrix rates. Nothing here is saved; test prints are marked
/// "TEST" so they can't be used as real tickets or receipts.
class PricingTestScreen extends StatefulWidget {
  const PricingTestScreen({super.key});

  @override
  State<PricingTestScreen> createState() => _PricingTestScreenState();
}

class _PricingTestScreenState extends State<PricingTestScreen> {
  VehicleType _type = VehicleType.car;
  late DateTime _timeIn = _today(8, 0);
  late DateTime _timeOut = _today(9, 0);
  bool _lostTicket = false;

  static DateTime _today(int h, int m) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, h, m);
  }

  ParkingTransaction get _ticket => ParkingTransaction(
        trackingId: 'TEST-0001',
        driverName: 'TEST DRIVER',
        plateNumber: 'TEST123',
        vehicleType: _type.label,
        fee: 0,
        zoneId: kZones.first.id,
        timestamp: _timeIn,
        collectorName: 'Test Collector',
      );

  /// The visit as the time-out tap would save it.
  ParkingTransaction get _paid {
    final p = FeeSettingsService.instance
        .quote(_type, _timeIn, _timeOut, lostTicket: _lostTicket);
    return _ticket.copyWith(
      timeOut: _timeOut,
      fee: p.baseFee,
      extraHours: p.extraHours,
      extraFee: p.extraFee,
      lostTicketFee: p.lostTicketFee,
    );
  }

  List<String> _ticketLines() {
    final printer = PrinterService.instance;
    final fees = FeeSettingsService.instance;
    return printer.timeInTicketLines(
      ticketNo: _ticket.trackingId,
      plateNumber: _ticket.plateNumber,
      vehicleType: _ticket.vehicleType,
      driverName: _ticket.driverName,
      zoneId: _ticket.zoneId,
      timeIn: _timeIn,
      rateLines: printer.rateLines(
        timeIn: _timeIn,
        baseFee: fees.feeFor(_type),
        baseHours: fees.baseHours,
        extraRate: fees.extraHourFeeFor(_type),
      ),
      lostTicketFee: fees.lostTicketFee,
      header: ['*** TEST ONLY ***', ...kReceiptHeader],
    );
  }

  List<String> _receiptLines() {
    final printer = PrinterService.instance;
    final tx = _paid;
    final parts = checkOutReceiptParts(tx);
    return [
      ...printer.previewLinesBeforeDriver(
          trackingId: tx.trackingId,
          header: ['*** TEST ONLY ***', ...kReceiptHeader]),
      '*** TIME OUT ***',
      printer.pair('Driver', tx.driverName),
      ...printer.previewLinesAfterDriver(
        plateNumber: tx.plateNumber,
        vehicleType: tx.vehicleType,
        zoneId: tx.zoneId,
        fee: tx.totalPaid,
        timestamp: _timeOut,
        footer: kOrdinanceRef,
        closingLines: parts.closingLines,
        paymentLines: parts.paymentLines,
        timeLines: parts.timeLines,
      ),
    ];
  }

  Future<void> _testPrint({required bool ticket}) async {
    final printer = PrinterService.instance;
    if (!printer.isConnected) {
      Toast.warn(context, t('Connect a printer first', 'Mag-connect muna ng printer'));
      return;
    }
    try {
      if (ticket) {
        final fees = FeeSettingsService.instance;
        await printer.printTimeInTicket(
          ticketNo: _ticket.trackingId,
          plateNumber: _ticket.plateNumber,
          vehicleType: _ticket.vehicleType,
          driverName: _ticket.driverName,
          zoneId: _ticket.zoneId,
          timeIn: _timeIn,
          rateLines: printer.rateLines(
            timeIn: _timeIn,
            baseFee: fees.feeFor(_type),
            baseHours: fees.baseHours,
            extraRate: fees.extraHourFeeFor(_type),
          ),
          lostTicketFee: fees.lostTicketFee,
          header: ['*** TEST ONLY ***', ...kReceiptHeader],
        );
      } else {
        final tx = _paid;
        final parts = checkOutReceiptParts(tx);
        await printer.printParkingTicket(
          trackingId: tx.trackingId,
          driverName: tx.driverName,
          plateNumber: tx.plateNumber,
          vehicleType: tx.vehicleType,
          zoneId: tx.zoneId,
          fee: tx.totalPaid,
          timestamp: _timeOut,
          header: ['*** TEST ONLY ***', ...kReceiptHeader],
          footer: kOrdinanceRef,
          banner: '*** TEST - NOT A RECEIPT ***',
          timeLines: parts.timeLines,
          paymentLines: parts.paymentLines,
          closingLines: parts.closingLines,
        );
      }
      if (mounted) Toast.success(context, t('Test printed', 'Na-print ang test'));
    } catch (e) {
      if (mounted) Toast.error(context, t('Print failed: $e', 'Nabigo: $e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fees = FeeSettingsService.instance;
    final p = fees.quote(_type, _timeIn, _timeOut, lostTicket: _lostTicket);
    Widget row(String label, String value, {bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
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
                      color: YosColors.ink,
                      fontSize: big ? 26 : 17,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        );
    Widget paper(String title, List<String> lines, VoidCallback onPrint) =>
        Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: YosColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: YosColors.glassBorder)),
          child: Column(
            children: [
              Text(title,
                  style: TextStyle(
                      color: YosColors.ink,
                      fontSize: 17,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(lines.join('\n'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: YosColors.ink,
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.6)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onPrint,
                icon: const Icon(Icons.print_rounded),
                label: Text(t('Test Print', 'I-test Print')),
              ),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Pricing Test', 'Pricing Test'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: YosColors.warn.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12)),
              child: Text(
                  t('TEMPORARY TEST TOOL — nothing here is saved. Uses the '
                      'current Fee Matrix rates.',
                      'PANSAMANTALANG TEST — walang nase-save dito. Gamit ang '
                      'kasalukuyang rates sa Fee Matrix.'),
                  style: TextStyle(
                      color: YosColors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in VehicleType.values)
                  ChoiceChip(
                    avatar: Icon(v.icon, size: 18),
                    label: Text(v.label),
                    selected: _type == v,
                    onSelected: (_) => setState(() => _type = v),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TimeChoiceButton(
                    label: t('TIME IN', 'PASOK'),
                    icon: Icons.login_rounded,
                    time: _timeIn,
                    highlight: true,
                    onTap: () async {
                      final picked = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(_timeIn),
                          initialEntryMode: TimePickerEntryMode.inputOnly);
                      if (picked != null) {
                        setState(() => _timeIn = DateTime(_timeIn.year,
                            _timeIn.month, _timeIn.day, picked.hour, picked.minute));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TimeChoiceButton(
                    label: t('TIME OUT', 'LABAS'),
                    icon: Icons.logout_rounded,
                    time: _timeOut,
                    highlight: true,
                    onTap: () async {
                      final picked = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(_timeOut),
                          initialEntryMode: TimePickerEntryMode.inputOnly);
                      if (picked != null) {
                        var out = DateTime(_timeIn.year, _timeIn.month,
                            _timeIn.day, picked.hour, picked.minute);
                        // Earlier than tap in = the next day (overnight).
                        if (out.isBefore(_timeIn)) {
                          out = out.add(const Duration(days: 1));
                        }
                        setState(() => _timeOut = out);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _lostTicket,
              onChanged: (v) => setState(() => _lostTicket = v),
              title: Text(t('Lost Ticket', 'Nawalang Ticket')),
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: YosColors.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: YosColors.glassBorder)),
              child: Column(
                children: [
                  row(t('Total Time', 'Kabuuang oras'), formatStay(p.stay)),
                  row(t('First ${p.baseHours} Hours', 'Unang ${p.baseHours} oras'),
                      '₱${p.baseFee.toStringAsFixed(0)}'),
                  row(
                      t('Extra ${p.extraHours} Hours × ₱${p.extraRate.toStringAsFixed(0)}',
                          'Dagdag ${p.extraHours} oras × ₱${p.extraRate.toStringAsFixed(0)}'),
                      '₱${p.extraFee.toStringAsFixed(0)}'),
                  if (p.lostTicketFee > 0)
                    row(t('Lost Ticket', 'Nawalang Ticket'),
                        '₱${p.lostTicketFee.toStringAsFixed(0)}'),
                  const Divider(height: 14),
                  row(t('Driver Pays', 'Babayaran'), '₱${p.total.toStringAsFixed(0)}',
                      big: true),
                ],
              ),
            ),
            paper(t('1) Printed at TAP IN - Ticket', '1) Ini-print sa PASOK - Ticket'),
                _ticketLines(), () => _testPrint(ticket: true)),
            paper(t('2) Printed at TAP OUT - Full Receipt', '2) Ini-print sa LABAS - Buong Resibo'),
                _receiptLines(), () => _testPrint(ticket: false)),
          ],
        ),
      ),
    );
  }
}
