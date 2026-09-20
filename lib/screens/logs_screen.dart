import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/pdf_export_service.dart';
import '../services/printer_service.dart';
import '../widgets/glow_effects.dart';
import '../widgets/pdf_export_search_dialog.dart';
import '../widgets/toast.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, this.embedded = false});

  /// True when hosted as a tab inside [RootShell] — hides the back arrow.
  final bool embedded;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  // Reads the embedded view's full transaction history for the "Export
  // PDF" search dialog below — see TransactionLogViewState.allTransactions.
  // Owned here, not by TransactionLogView itself, so the export button can
  // live in this screen's own AppBar, same placement AuditScreen's "Export
  // PDF" uses.
  final _logsKey = GlobalKey<TransactionLogViewState>();

  /// Opens a dedicated search dialog on top of the PDF button — typing
  /// there narrows down exactly which transactions go into the export,
  /// independent of whatever this screen's own search/time filter/
  /// Show-count are currently set to.
  Future<void> _exportPdf() async {
    final all = _logsKey.currentState?.allTransactions ?? const [];
    if (all.isEmpty) {
      Toast.warn(context, t('Nothing to export yet.', 'Wala pang ie-export.'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => PdfExportSearchDialog<ParkingTransaction>(
        items: all,
        hintText:
            t('Plate, receipt ID, or driver…', 'Plaka, receipt ID, o driver…'),
        matches: (tx, q) {
          final query = q.toUpperCase();
          return tx.plateNumber.toUpperCase().contains(query) ||
              tx.trackingId.toUpperCase().contains(query) ||
              tx.driverName.toUpperCase().contains(query);
        },
        itemLabel: (tx) => '${tx.trackingId} · ${tx.plateNumber} · '
            '${tx.driverName}',
        onExport: _generatePdf,
      ),
    );
  }

  Future<void> _generatePdf(List<ParkingTransaction> txs) async {
    try {
      final dateFmt = DateFormat('MMM d, yyyy');
      final timeFmt = DateFormat('hh:mm:ss a');
      final totalFee = txs.fold<double>(0, (s, tx) => s + tx.fee);
      await PdfExportService.exportTable(
        title: t('Transaction Logs', 'Mga Transaksyon'),
        headers: [
          '#',
          t('Date', 'Petsa'),
          t('Time', 'Oras'),
          t('Tracking ID', 'Tracking ID'),
          t('Plate', 'Plaka'),
          t('Driver', 'Driver'),
          t('Fee', 'Bayad'),
          t('Status', 'Katayuan'),
        ],
        rows: [
          for (var i = 0; i < txs.length; i++)
            [
              '${i + 1}',
              dateFmt.format(txs[i].timestamp),
              timeFmt.format(txs[i].timestamp),
              txs[i].trackingId,
              txs[i].plateNumber,
              txs[i].driverName,
              'PHP ${txs[i].fee.toStringAsFixed(0)}',
              txs[i].pendingSync
                  ? t('Syncing', 'Nag-sync')
                  : t('Paid', 'Bayad'),
            ],
        ],
        summary: [
          MapEntry(t('Total transactions', 'Kabuuang Transaksyon'),
              '${txs.length}'),
          MapEntry(t('Total collected', 'Kabuuang Nakolekta'),
              'PHP ${totalFee.toStringAsFixed(0)}'),
        ],
      );
      if (mounted) {
        Toast.success(context, t('PDF sent to share sheet', 'Naipadala ang PDF'));
      }
    } catch (e) {
      if (mounted) {
        Toast.error(context,
            t("Couldn't export PDF: $e", 'Hindi na-export ang PDF: $e'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded ? null : const BackButton(),
        title: Text(t('Transaction Logs', 'Mga Transaksyon'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: t('Export PDF', 'I-export bilang PDF'),
            onPressed: _exportPdf,
            icon: const Icon(Icons.picture_as_pdf_rounded),
          ),
        ],
      ),
      body: TouchGlowOverlay(
        child: SafeArea(child: TransactionLogView(key: _logsKey)),
      ),
    );
  }
}

enum _TimeFilter { all, today, hour, month }

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
  State<TransactionLogView> createState() => TransactionLogViewState();
}

/// Public (not `_`-prefixed) so a host screen outside this file — see
/// AuditScreen's Entries tab — can hold a `GlobalKey<TransactionLogViewState>`
/// on its embedded [TransactionLogView] and read [visibleTransactions] for
/// its own "Export PDF" action, same as [LogsScreen] does for its own copy.
class TransactionLogViewState extends State<TransactionLogView> {
  final _search = TextEditingController();
  _TimeFilter _filter = _TimeFilter.all;
  Timer? _auditDebounce;

  /// Caps how many (already filtered/searched) rows are shown at once —
  /// null means no cap ("All"). Keeps a long history scannable instead of
  /// always rendering every matching entry.
  int? _limit = 20;

  /// Latest rendered rows (search + time filter + Show-count already
  /// applied) — set (not via setState) from inside the StreamBuilder
  /// below, purely so a host screen's own "Export PDF" button (see
  /// LogsScreen._exportPdf) can read exactly what's currently on screen
  /// without a second Firestore read or re-deriving the filter here. Same
  /// pattern AuditScreen's own _visibleLogs uses.
  List<ParkingTransaction> _visibleTxs = const [];
  List<ParkingTransaction> get visibleTransactions => _visibleTxs;

  /// Every transaction from the live stream, before this widget's own
  /// search/time filter/Show-count are applied — a host screen's "Export
  /// PDF" search dialog runs its own independent query across full history
  /// with this, rather than being limited to whatever's currently filtered
  /// on screen (see LogsScreen._exportPdf / AuditScreen._exportPdf).
  List<ParkingTransaction> _allTxs = const [];
  List<ParkingTransaction> get allTransactions => _allTxs;

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
        _TimeFilter.month =>
          t.timestamp.isAfter(DateTime(now.year, now.month - 1, now.day)),
      };
      return matchesQuery && matchesTime;
    }).toList();
  }

  List<ParkingTransaction> _applyLimit(List<ParkingTransaction> txs) {
    final limit = _limit;
    return limit == null || txs.length <= limit
        ? txs
        : txs.sublist(0, limit);
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
              // Both pickers as dropdowns, not a chip row — a chip per
              // time-filter option outgrew a single line on a narrow phone
              // even scrolling sideways; a dropdown takes the same width
              // regardless of how many options it has, so this always sits
              // on one line next to the "Show" count picker, by request.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(t('Filter', 'Salain'),
                        style: TextStyle(
                            color: YosColors.sub,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    DropdownButton<_TimeFilter>(
                      value: _filter,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: [
                        for (final (f, label) in [
                          (_TimeFilter.all, t('All', 'Lahat')),
                          (_TimeFilter.today, t('Today', 'Ngayon')),
                          (_TimeFilter.hour, t('Last Hour', 'Huling Oras')),
                          (_TimeFilter.month,
                              t('Last Month', 'Nakaraang Buwan')),
                        ])
                          DropdownMenuItem(value: f, child: Text(label)),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _filter = v);
                      },
                    ),
                    const SizedBox(width: 20),
                    Text(t('Show', 'Ipakita'),
                        style: TextStyle(
                            color: YosColors.sub,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    DropdownButton<int?>(
                      value: _limit,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: [
                        for (final n in [10, 20, 50])
                          DropdownMenuItem(value: n, child: Text('$n')),
                        DropdownMenuItem(
                            value: null, child: Text(t('All', 'Lahat'))),
                      ],
                      onChanged: (v) => setState(() => _limit = v),
                    ),
                  ],
                ),
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
              _allTxs = snap.data!;
              final filtered = _apply(snap.data!);
              final txs = _applyLimit(filtered);
              _visibleTxs = txs;
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
