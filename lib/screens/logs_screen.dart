import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/printer_service.dart';
import '../widgets/glow_effects.dart';
import '../widgets/toast.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, this.embedded = false});

  /// True when hosted as a tab inside [RootShell] — hides the back arrow.
  final bool embedded;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded ? null : const BackButton(),
        title: Text(t('Transaction Logs', 'Mga Transaksyon'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: const TouchGlowOverlay(
        child: SafeArea(child: TransactionLogView()),
      ),
    );
  }
}

enum _TimeFilter { all, today, hour }

/// The actual search + time-filter + full transaction list — every entry
/// ever logged (last week, yesterday, today, all of it; [allTransactions]
/// has no date window, just a most-recent cap), newest first. Its own
/// widget (rather than baked into [LogsScreen]) so AuditScreen's Entries
/// tab can embed the exact same live view for transparency, instead of a
/// separate audit-log-derived summary that could drift from what
/// Transaction logs actually shows.
class TransactionLogView extends StatefulWidget {
  const TransactionLogView({super.key});

  @override
  State<TransactionLogView> createState() => _TransactionLogViewState();
}

class _TransactionLogViewState extends State<TransactionLogView> {
  final _search = TextEditingController();
  _TimeFilter _filter = _TimeFilter.all;
  Timer? _auditDebounce;

  // Grabbed once, not called fresh inside build() — the search box's own
  // setState on every keystroke would otherwise hand StreamBuilder a
  // brand-new Stream instance each time, which is what causes Flutter's
  // "'_dependents.isEmpty': is not true" crash. Same `late final` pattern
  // used across the other screens with a live Firestore stream.
  late final Stream<List<ParkingTransaction>> _txs =
      YosRepository.instance.allTransactions();

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      setState(() {});
      _auditDebounce?.cancel();
      final q = _search.text.trim();
      if (q.length >= 3) {
        _auditDebounce = Timer(const Duration(seconds: 2), () {
          YosRepository.instance
              .logAudit(AuditAction.search, 'Searched logs for "$q"');
        });
      }
    });
  }

  @override
  void dispose() {
    _auditDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  List<ParkingTransaction> _apply(List<ParkingTransaction> txs) {
    final q = _search.text.trim().toUpperCase();
    final now = DateTime.now();
    return txs.where((t) {
      final matchesQuery = q.isEmpty ||
          t.plateNumber.contains(q) ||
          t.trackingId.toUpperCase().contains(q) ||
          t.driverName.toUpperCase().contains(q);
      final matchesTime = switch (_filter) {
        _TimeFilter.all => true,
        _TimeFilter.today =>
          t.timestamp.isAfter(DateTime(now.year, now.month, now.day)),
        _TimeFilter.hour =>
          t.timestamp.isAfter(now.subtract(const Duration(hours: 1))),
      };
      return matchesQuery && matchesTime;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(
            children: [
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t('Plate, receipt ID, or driver…',
                      'Plaka, receipt ID, o driver…'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: t('Clear search', 'I-clear ang paghahanap'),
                          onPressed: () => _search.clear(),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              // Wrap, not Row: on a narrow phone or a bumped-up
              // accessibility text scale, three chips can outgrow one
              // line — Wrap drops the extra chip to a second line
              // instead of overflowing off the right edge.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (f, label) in [
                    (_TimeFilter.all, t('All', 'Lahat')),
                    (_TimeFilter.today, t('Today', 'Ngayon')),
                    (_TimeFilter.hour, t('Last hour', 'Huling Oras')),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _filter == f,
                      selectedColor: YosColors.sage,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<ParkingTransaction>>(
            stream: _txs,
            builder: (context, snap) {
              if (snap.hasError) {
                return const _ErrorState();
              }
              if (!snap.hasData) {
                return const _LogsSkeleton();
              }
              final txs = _apply(snap.data!);
              if (txs.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inbox_rounded,
                            size: 56, color: YosColors.sub),
                        const SizedBox(height: 12),
                        Text(
                          _search.text.isEmpty
                              ? t('No entries yet.\nLog a vehicle to start.',
                                  'Wala pang entries.\nMag-log ng sasakyan para magsimula.')
                              : t(
                                  'No matches.\nTry a different plate or ID.',
                                  'Walang tugma.\nSubukan ang ibang plaka o ID.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: YosColors.sub,
                              fontSize: 15,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                itemCount: txs.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: PopIn(
                    delayMs: (i * 40).clamp(0, 400),
                    child: _TxCard(tx: txs[i], index: i),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TxCard extends StatelessWidget {
  const _TxCard({required this.tx, required this.index});
  final ParkingTransaction tx;
  final int index;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('MMM d, hh:mm a').format(tx.timestamp);
    final (statusLabel, statusColor) = tx.pendingSync
        ? (t('SYNCING', 'NAG-SYNC'), YosColors.warn)
        : (t('PAID', 'BAYAD'), YosColors.good);

    return MergeSemantics(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => _TxDetailDialog(tx: tx),
          ),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: YosColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: YosColors.glassBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Row number in the currently visible (filtered/searched)
                    // list — a plain running count, not a stable ID, so it
                    // shifts as the search/time filter narrows the list.
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: YosColors.sub.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('${index + 1}',
                          style: TextStyle(
                              color: YosColors.sub,
                              fontWeight: FontWeight.w800,
                              fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text('#${tx.trackingId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: YosColors.ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              letterSpacing: 0.4)),
                    ),
                    const Spacer(),
                    if (tx.printed)
                      Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: ExcludeSemantics(
                          child: Icon(Icons.print_rounded,
                              size: 14, color: YosColors.sub),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(statusLabel,
                          style: TextStyle(
                              color: statusColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('${tx.plateNumber} · ${tx.driverName}',
                    style: TextStyle(
                        color: YosColors.sub,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(date,
                        style: TextStyle(
                            color: YosColors.sub,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    const Spacer(),
                    Text('₱${tx.fee.toStringAsFixed(0)}',
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 16)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full transaction detail, opened by tapping a [_TxCard] — every field the
/// list row itself doesn't have room for (vehicle type, zone, exact
/// timestamp), plus a one-tap reprint. Close (✕) sits in the header instead
/// of a bottom "Close" button, since the bottom slot is reserved for the
/// one real action here — reprinting — so it can span the dialog's full
/// width edge-to-edge instead of sharing the row with a secondary button.
class _TxDetailDialog extends StatefulWidget {
  const _TxDetailDialog({required this.tx});
  final ParkingTransaction tx;

  @override
  State<_TxDetailDialog> createState() => _TxDetailDialogState();
}

class _TxDetailDialogState extends State<_TxDetailDialog> {
  bool _printing = false;

  Future<void> _print() async {
    final printer = PrinterService.instance;
    if (!printer.isConnected) {
      Toast.warn(context, t('Connect a printer first', 'Kumonekta muna sa printer'));
      return;
    }
    setState(() => _printing = true);
    try {
      final tx = widget.tx;
      await printer.printParkingTicket(
        trackingId: tx.trackingId,
        driverName: tx.driverName,
        plateNumber: tx.plateNumber,
        vehicleType: tx.vehicleType,
        zoneId: tx.zoneId,
        fee: tx.fee,
        timestamp: tx.timestamp,
        header: kReceiptHeader,
        footer: kOrdinanceRef,
      );
      HapticFeedback.heavyImpact();
      if (mounted) Toast.success(context, t('Receipt printed', 'Na-print ang resibo'));
    } catch (e) {
      if (mounted) Toast.error(context, t('Print failed', 'Hindi na-print'));
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;
    final date = DateFormat('MMM d, y · hh:mm a').format(tx.timestamp);
    final (statusLabel, statusColor) = tx.pendingSync
        ? (t('Syncing', 'Nag-sync'), YosColors.warn)
        : (t('Paid', 'Bayad'), YosColors.good);
    const radius = 24.0;

    return Dialog(
      backgroundColor: YosColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(t('Transaction Details', 'Detalye ng Transaksyon'),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: YosColors.ink)),
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
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              children: [
                _DetailRow(
                    icon: Icons.receipt_long_rounded,
                    label: t('Receipt ID', 'Receipt ID'),
                    value: '#${tx.trackingId}'),
                _DetailRow(
                    icon: Icons.person_rounded,
                    label: t('Driver', 'Driver'),
                    value: tx.driverName),
                _DetailRow(
                    icon: Icons.directions_car_rounded,
                    label: t('Plate · Vehicle', 'Plaka · Sasakyan'),
                    value: '${tx.plateNumber} · ${tx.vehicleType}'),
                _DetailRow(
                    icon: Icons.place_rounded,
                    label: t('Zone', 'Zone'),
                    value: tx.zoneId),
                _DetailRow(
                    icon: Icons.schedule_rounded,
                    label: t('Date & Time', 'Petsa at Oras'),
                    value: date),
                _DetailRow(
                    icon: Icons.payments_rounded,
                    label: t('Fee Collected', 'Naningil na Bayad'),
                    value: tx.discount > 0
                        ? '₱${tx.fee.toStringAsFixed(0)} (was '
                            '₱${(tx.fee + tx.discount).toStringAsFixed(0)})'
                        : '₱${tx.fee.toStringAsFixed(0)}'),
                // Only shown once a redemption actually happened — most
                // transactions have nothing here, so there's no "Discount:
                // ₱0" clutter on the common case.
                if (tx.discount > 0)
                  _DetailRow(
                      icon: Icons.redeem_rounded,
                      label: t('Discount', 'Diskwento'),
                      value: t(
                          '-₱${tx.discount.toStringAsFixed(0)} (points redeemed)',
                          '-₱${tx.discount.toStringAsFixed(0)} (na-redeem na points)'),
                      valueColor: YosColors.good),
                _DetailRow(
                  icon: tx.pendingSync
                      ? Icons.sync_rounded
                      : Icons.check_circle_rounded,
                  label: t('Status', 'Katayuan'),
                  value: tx.printed
                      ? '$statusLabel · ${t('Printed', 'Na-print')}'
                      : statusLabel,
                  valueColor: statusColor,
                  isLast: true,
                ),
              ],
            ),
          ),
          // A standalone rounded (pill) button with its own margin, not
          // flush with the dialog's edges — matching the shape every other
          // button in this app uses, rather than merging into the dialog
          // chrome itself.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Material(
              color: YosColors.accent,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: _printing ? null : _print,
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  alignment: Alignment.center,
                  child: _printing
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: YosColors.onAccent),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.print_rounded,
                                size: 18, color: YosColors.onAccent),
                            const SizedBox(width: 8),
                            Text(
                                tx.printed
                                    ? t('Reprint Receipt', 'I-reprint ang Resibo')
                                    : t('Print Receipt', 'I-print ang Resibo'),
                                style: TextStyle(
                                    color: YosColors.onAccent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15)),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One icon-badge + label/value row inside [_TxDetailDialog].
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.isLast = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: YosColors.accentSoft,
                borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: YosColors.accentDeep),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: YosColors.ink)),
                const SizedBox(height: 2),
                Text(value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: valueColor ?? YosColors.sub,
                        fontWeight: valueColor != null
                            ? FontWeight.w700
                            : FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading placeholder shaped like a page of transaction cards, so the
/// list doesn't jump when the first snapshot arrives.
class _LogsSkeleton extends StatelessWidget {
  const _LogsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SkeletonBox(height: 94, borderRadius: 16),
          ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, size: 56, color: YosColors.sub),
            const SizedBox(height: 16),
            Text(
              t("Couldn't load transaction logs.",
                  'Hindi na-load ang mga transaksyon.'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: YosColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 17),
            ),
            const SizedBox(height: 6),
            Text(
              t(
                  'Check your connection — this list updates automatically '
                      'once you\'re back online.',
                  'Tingnan ang iyong koneksyon — awtomatikong mag-u-update '
                      'ang listahang ito kapag online ka na ulit.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: YosColors.sub, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}
