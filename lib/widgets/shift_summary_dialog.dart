import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import 'glass_card.dart';

/// The signed-in collector's own totals for today — what they should be
/// holding when they hand over the day's money. Credited the same way as
/// the blotter's By Collector (ParkingTransaction.collectedById), so the
/// two always agree.
class ShiftSummary {
  ShiftSummary(List<ParkingTransaction> today, String uid)
      : mine = today.where((tx) => tx.collectedById == uid).toList(),
        stillParked = today
            .where((tx) => tx.collectorId == uid && tx.awaitingCheckout)
            .length;

  final List<ParkingTransaction> mine;

  /// Vehicles this collector timed in today that haven't timed out.
  final int stillParked;

  int get vehicles => mine.where((tx) => tx.totalPaid > 0).length;
  double get total => mine.fold(0, (s, tx) => s + tx.totalPaid);
  Map<String, double> get byMethod => amountsByMethod(mine);
  double get cash => byMethod[PaymentMethod.cash] ?? 0;
}

/// The collector's own slice of a day, shown on top of the Daily
/// Blotter's whole-day summary (collectors only).
class ShiftSummaryCard extends StatelessWidget {
  const ShiftSummaryCard({super.key, required this.summary});
  final ShiftSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    String php(double v) => '₱${NumberFormat('#,##0.00').format(v)}';
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_turned_in_rounded,
                  color: YosColors.ink, size: 20),
              const SizedBox(width: 8),
              Text(t('My Shift', 'Aking Shift'),
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 18)),
            ],
          ),
          const SizedBox(height: 8),
          Text(php(s.total),
              style: TextStyle(
                  color: YosColors.ink,
                  fontSize: 26,
                  fontWeight: FontWeight.w900)),
          Text(
              t('Collected From ${s.vehicles} Vehicle${s.vehicles == 1 ? '' : 's'}',
                  'Nakolekta mula sa ${s.vehicles} sasakyan'),
              style: TextStyle(color: YosColors.sub, fontSize: 13)),
          const Divider(height: 20),
          for (final e in s.byMethod.entries)
            _row(PaymentMethod.label(e.key), php(e.value)),
          if (s.stillParked > 0)
            _row(
                t('Still Parked (Not Yet Paid)',
                    'Nakaparada Pa (Hindi Pa Bayad)'),
                '${s.stillParked}'),
          _row(t('Cash to Hand Over', 'Cash na Iaabot'), php(s.cash),
              bold: true),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: bold ? YosColors.ink : YosColors.sub,
                      fontSize: bold ? 16 : 14,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
            ),
            Text(value,
                style: TextStyle(
                    color: YosColors.ink,
                    fontSize: bold ? 17 : 14,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      );
}

/// Shows today's shift summary. With [forLogout], it doubles as the
/// log-out confirmation and resolves true when the collector confirms;
/// otherwise it's view-only and resolves null.
Future<bool?> showShiftSummaryDialog(BuildContext context,
    {bool forLogout = false}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  final now = DateTime.now();
  List<ParkingTransaction> today = const [];
  try {
    today = await YosRepository.instance.transactionsForDate(now);
  } catch (e) {
    debugPrint('shift summary load failed (showing zeros): $e');
  }
  if (!context.mounted) return null;
  final s = ShiftSummary(today, uid ?? '');
  String php(double v) => '₱${NumberFormat('#,##0.00').format(v)}';

  Widget row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: bold ? YosColors.ink : YosColors.sub,
                      fontSize: bold ? 16 : 14,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
            ),
            Text(value,
                style: TextStyle(
                    color: YosColors.ink,
                    fontSize: bold ? 17 : 14,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      );

  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.assignment_turned_in_rounded),
      title: Text(t('My Shift Summary', 'Buod ng Aking Shift'),
          style: const TextStyle(fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(DateFormat('EEEE, MMM d, yyyy').format(now),
              textAlign: TextAlign.center,
              style: TextStyle(color: YosColors.sub, fontSize: 13)),
          const SizedBox(height: 10),
          Text(php(s.total),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: YosColors.ink,
                  fontSize: 30,
                  fontWeight: FontWeight.w900)),
          Text(
              t('Collected From ${s.vehicles} Vehicle${s.vehicles == 1 ? '' : 's'}',
                  'Nakolekta mula sa ${s.vehicles} sasakyan'),
              textAlign: TextAlign.center,
              style: TextStyle(color: YosColors.sub, fontSize: 13)),
          const Divider(height: 22),
          for (final e in s.byMethod.entries)
            row(PaymentMethod.label(e.key), php(e.value)),
          if (s.stillParked > 0)
            row(
                t('Still Parked (Not Yet Paid)',
                    'Nakaparada Pa (Hindi Pa Bayad)'),
                '${s.stillParked}'),
          const Divider(height: 22),
          row(t('Cash to Hand Over', 'Cash na Iaabot'), php(s.cash),
              bold: true),
          if (forLogout && s.stillParked > 0) ...[
            const SizedBox(height: 10),
            Text(
                t('Some vehicles you timed in are still parked. Another collector can time them out.',
                    'May mga sasakyang ipinasok mo na nakaparada pa. Ibang kolektor ang puwedeng maglabas sa kanila.'),
                style: const TextStyle(color: YosColors.warn, fontSize: 13)),
          ],
        ],
      ),
      actions: forLogout
          ? [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(t('Cancel', 'Kanselahin'))),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: YosColors.bad),
                onPressed: () => Navigator.of(ctx).pop(true),
                icon: const Icon(Icons.logout_rounded),
                label: Text(t('Log Out', 'Mag-log Out')),
              ),
            ]
          : [
              FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(t('Close', 'Isara'))),
            ],
    ),
  );
}
