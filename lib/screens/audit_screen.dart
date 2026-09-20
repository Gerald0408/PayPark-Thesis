import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/pdf_export_service.dart';
import '../services/points_settings_service.dart' show formatPoints;
import '../widgets/glow_effects.dart';
import '../widgets/pdf_export_search_dialog.dart';
import '../widgets/toast.dart';
import 'logs_screen.dart';

/// Access events live in their own tab, apart from operational activity.
const Set<String> _accessActions = {
  AuditAction.login,
  AuditAction.logout,
  AuditAction.loginFailed,
  AuditAction.register,
  AuditAction.faceEnroll,
  AuditAction.faceIdRemoved,
  AuditAction.faceLoginSuccess,
  AuditAction.faceLoginFailed,
  AuditAction.passwordReset,
  AuditAction.accessRequestResolved,
  AuditAction.adminPromoted,
  AuditAction.adminDemoted,
};

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

enum _AuditTab { activity, access, entries }

/// Every audit event a logged parking transaction can produce — a save
/// always logs [AuditAction.newEntry], and printing on top of that also
/// logs [AuditAction.printReceipt] (see YosRepository.saveTransaction).
/// Excluded from the Activity tab, which shows everything else: the
/// Entries tab covers this ground on its own, and shows the real
/// transaction records (via [TransactionLogView]) rather than these
/// audit-log lines about them.
const Set<String> _transactionActions = {
  AuditAction.newEntry,
  AuditAction.printReceipt,
};

class _AuditScreenState extends State<AuditScreen> with WidgetsBindingObserver {
  _AuditTab _tab = _AuditTab.activity;

  // Grabbed once, not called fresh inside build() — sorting/tab-switching
  // both call setState here, which would otherwise hand StreamBuilder a
  // brand-new Stream instance every time, the exact trigger for Flutter's
  // "'_dependents.isEmpty': is not true" crash. Same `late final` pattern
  // used across the other screens with a live Firestore stream.
  late final Stream<List<AuditLog>> _auditLogs =
      YosRepository.instance.auditLogs();

  // Reads the embedded Entries view's currently visible (search +
  // time-filter + Show-count applied) rows for export — same pattern
  // LogsScreen's own _logsKey uses for its copy of TransactionLogView.
  final _entriesKey = GlobalKey<TransactionLogViewState>();

  // Column indices into the DataTable below: 2 = Date, 3 = Time,
  // 4 = Event, 5 = Actor. Columns 0 (row #) and 1 (sync status) aren't
  // sortable — row # always just reflects whatever order the rest of the
  // sort produced.
  int _sortColumnIndex = 2;
  bool _sortAscending = false; // newest first by default

  // Latest rendered rows for whichever tab is active — set (not via
  // setState) from inside the StreamBuilder below, purely so _exportPdf
  // has something to hand off without re-deriving the filter/sort itself.
  List<AuditLog> _visibleLogs = const [];

  // Anchors the post-export popup to the PDF button itself (see
  // _showPdfPopup) using its actual global screen position rather than a
  // LayerLink — the button lives inside the AppBar, and a
  // CompositedTransformFollower inserted into a non-root Overlay ended up
  // computing its position in a different coordinate space than the
  // leader, landing the popup off in the top-left corner instead of next
  // to the button.
  final GlobalKey _pdfButtonKey = GlobalKey();
  OverlayEntry? _pdfPopupEntry;

  // Printing.sharePdf's future resolves as soon as the OS share sheet is
  // launched, not when the user finishes with it (there's no callback for
  // when the receiving app, e.g. Bluetooth, finishes the transfer — that
  // handoff happens entirely outside our process). So instead of popping
  // the message up right away, stash it and wait for the app to resume,
  // which fires when the user backs out of or completes the share sheet
  // flow — the closest signal available for "done exporting."
  String? _pendingPopupMessage;
  bool _pendingPopupIsError = false;
  bool _awaitingShareReturn = false;

  // uid -> name, for logs written before AuditLog.actorName existed (see
  // _actorDisplay). Admin-only reads (allCollectors/trashedCollectors), so
  // this silently stays empty for a non-admin viewer — no worse than what
  // they already saw, just not upgraded either. Loaded once and folded in
  // via setState rather than a second StreamBuilder, so the audit table
  // itself never has to wait on this before it can render.
  Map<String, String> _actorNamesByUid = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadActorNames();
  }

  Future<void> _loadActorNames() async {
    // Fetched independently, not both inside one try — trashedCollectors()
    // failing (e.g. this viewer isn't an admin, so that read alone is
    // denied) must not also throw away a perfectly good allCollectors()
    // result; every historical row would fall back to its raw uid
    // otherwise, even the ones a plain collectors-list lookup could've
    // resolved fine.
    final merged = <String, String>{};
    try {
      final active = await YosRepository.instance.allCollectors().first;
      merged.addEntries(active.map((c) => MapEntry(c.uid, c.name)));
    } catch (_) {
      // Not an admin, offline, or nothing to resolve — actorId fallback
      // (see _actorDisplay) covers this fine.
    }
    try {
      final trashed = await YosRepository.instance.trashedCollectors().first;
      merged.addEntries(trashed.map((c) => MapEntry(c.uid, c.name)));
    } catch (_) {}
    if (!mounted || merged.isEmpty) return;
    setState(() => _actorNamesByUid = merged);
  }

  /// The Actor column's actual text: the name snapshotted when the log was
  /// written (see YosRepository.logAudit) if it has one, else a best-effort
  /// live lookup by uid for older logs from before that existed, else the
  /// raw actorId as the last resort (also what a failed-login row already
  /// legitimately shows — actorId there is the attempted email, not a uid).
  String _actorDisplay(AuditLog log) =>
      log.actorName ?? _actorNamesByUid[log.actorId] ?? log.actorId;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pdfPopupEntry?.remove();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_awaitingShareReturn) return;
    _awaitingShareReturn = false;
    final message = _pendingPopupMessage;
    final isError = _pendingPopupIsError;
    _pendingPopupMessage = null;
    if (message == null) return;
    // The button's RenderBox isn't ready to measure until this frame
    // finishes settling back in from the share sheet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showPdfPopup(message, isError: isError);
    });
  }

  void _queuePdfPopup(String message, {bool isError = false}) {
    if (isError) {
      // Nothing to wait for — export itself failed before any share sheet
      // ever opened, so show it immediately.
      _showPdfPopup(message, isError: true);
      return;
    }
    _pendingPopupMessage = message;
    _pendingPopupIsError = isError;
    _awaitingShareReturn = true;
  }

  void _showPdfPopup(String message, {bool isError = false}) {
    _pdfPopupEntry?.remove();
    final box = _pdfButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final buttonTopLeft = box.localToGlobal(Offset.zero);
    final buttonSize = box.size;
    final screenWidth = MediaQuery.of(context).size.width;
    final fg = isError ? YosColors.bad : YosColors.good;
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        top: buttonTopLeft.dy + buttonSize.height / 2 - 16,
        right: screenWidth - buttonTopLeft.dx + 8,
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: YosColors.surface,
              borderRadius: BorderRadius.circular(12),
              boxShadow: kSoftShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isError ? Icons.error_rounded : Icons.check_circle_rounded,
                  size: 16,
                  color: fg,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    message,
                    style: TextStyle(
                        color: fg, fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _pdfPopupEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (_pdfPopupEntry == entry) {
        entry.remove();
        _pdfPopupEntry = null;
      }
    });
  }

  int _compare(AuditLog a, AuditLog b) {
    final cmp = switch (_sortColumnIndex) {
      2 || 3 => a.timestamp.compareTo(b.timestamp),
      4 => a.description.compareTo(b.description),
      5 => _actorDisplay(a).compareTo(_actorDisplay(b)),
      _ => 0,
    };
    return _sortAscending ? cmp : -cmp;
  }

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
    });
  }

  (IconData, Color) _style(String action) => switch (action) {
        AuditAction.login => (Icons.login_rounded, YosColors.mint),
        AuditAction.logout => (Icons.logout_rounded, YosColors.seafoam),
        // Kept off the green family on purpose: this is a failed-login
        // security event in an append-only audit trail, and a green badge
        // next to "gpp_bad" would read as "this was fine."
        AuditAction.loginFailed => (Icons.gpp_bad_rounded, YosColors.badSoft),
        AuditAction.register => (Icons.person_add_rounded, YosColors.mint),
        AuditAction.faceEnroll => (
            Icons.face_retouching_natural,
            YosColors.seafoam
          ),
        AuditAction.faceIdRemoved => (
            Icons.no_accounts_rounded,
            YosColors.badSoft
          ),
        AuditAction.faceLoginSuccess => (
            Icons.face_retouching_natural,
            YosColors.mint
          ),
        AuditAction.faceLoginFailed => (
            Icons.gpp_bad_rounded,
            YosColors.badSoft
          ),
        AuditAction.newEntry => (Icons.add_road_rounded, YosColors.mint),
        AuditAction.search => (Icons.search_rounded, YosColors.seafoam),
        // goodSoft, not mint — mint (like every mint/seafoam/pistachio/
        // sage/moss token in this palette) is a blue pastel now, not
        // green, so it read as just another neutral badge instead of a
        // clear "this is good" signal.
        AuditAction.syncOnline => (
            Icons.cloud_done_rounded,
            YosColors.goodSoft
          ),
        // badSoft, not pistachio — pistachio is the same repurposed-blue
        // problem as mint above, so a lost-connection event read as just
        // another shade of "fine" rather than the danger state it
        // actually is. badSoft matches every other danger badge here
        // (loginFailed, faceLoginFailed, faceIdRemoved).
        AuditAction.syncOffline => (Icons.cloud_off_rounded, YosColors.badSoft),
        AuditAction.backup => (Icons.save_rounded, YosColors.sage),
        AuditAction.printReceipt => (Icons.print_rounded, YosColors.moss),
        AuditAction.pointsEarned => (Icons.loyalty_rounded, YosColors.mint),
        AuditAction.pointsRedeemed => (Icons.redeem_rounded, YosColors.seafoam),
        AuditAction.passwordReset => (
            Icons.lock_reset_rounded,
            YosColors.seafoam
          ),
        AuditAction.accessRequestResolved => (
            Icons.notifications_active_rounded,
            YosColors.pistachio
          ),
        AuditAction.adminPromoted => (Icons.shield_rounded, YosColors.mint),
        AuditAction.adminDemoted => (
            Icons.remove_moderator_rounded,
            YosColors.warnSoft
          ),
        AuditAction.deactivateCollector => (
            Icons.person_remove_rounded,
            YosColors.badSoft
          ),
        AuditAction.restoreCollector => (Icons.restore_rounded, YosColors.mint),
        AuditAction.permanentlyDeleteCollector => (
            Icons.delete_forever_rounded,
            YosColors.badSoft
          ),
        _ => (Icons.circle_outlined, YosColors.seafoam),
      };

  /// Opens a dedicated search dialog on top of the PDF button for whichever
  /// tab is currently open — typing there narrows down exactly which
  /// records go into the export, independent of whatever search/time
  /// filter/Show-count or sort this screen's own table is currently set
  /// to. Entries searches the embedded [TransactionLogView]'s full
  /// transaction history (read off [_entriesKey], same as LogsScreen);
  /// Activity/Access search the current tab's own rows (already
  /// tab-filtered — Access vs. general Activity is a deliberate scope, not
  /// a transient one).
  Future<void> _exportPdf() async {
    if (_tab == _AuditTab.entries) {
      final all = _entriesKey.currentState?.allTransactions ?? const [];
      if (all.isEmpty) {
        Toast.warn(context, t('Nothing to export yet.', 'Wala pang ie-export.'));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => PdfExportSearchDialog<ParkingTransaction>(
          items: all,
          hintText: t(
              'Plate, receipt ID, or driver…', 'Plaka, receipt ID, o driver…'),
          matches: (tx, q) {
            final query = q.toUpperCase();
            return tx.plateNumber.toUpperCase().contains(query) ||
                tx.trackingId.toUpperCase().contains(query) ||
                tx.driverName.toUpperCase().contains(query);
          },
          itemLabel: (tx) => '${tx.trackingId} · ${tx.plateNumber} · '
              '${tx.driverName}',
          onExport: _generateEntriesPdf,
        ),
      );
      return;
    }
    final logs = _visibleLogs;
    if (logs.isEmpty) {
      Toast.warn(context, t('Nothing to export yet.', 'Wala pang ie-export.'));
      return;
    }
    final tab = _tab;
    await showDialog<void>(
      context: context,
      builder: (_) => PdfExportSearchDialog<AuditLog>(
        items: logs,
        hintText: t('Event or actor…', 'Pangyayari o gumawa…'),
        matches: (log, q) {
          final query = q.toUpperCase();
          return log.description.toUpperCase().contains(query) ||
              _actorDisplay(log).toUpperCase().contains(query);
        },
        itemLabel: (log) => '${log.description} — ${_actorDisplay(log)}',
        onExport: (matched) => _generateActivityPdf(matched, tab),
      ),
    );
  }

  Future<void> _generateEntriesPdf(List<ParkingTransaction> txs) async {
    try {
      final dateFmt = DateFormat('MMM d, yyyy');
      final timeFmt = DateFormat('hh:mm:ss a');
      final totalFee = txs.fold<double>(0, (s, tx) => s + tx.fee);
      await PdfExportService.exportTable(
        title: t('Transaction entries', 'Mga Transaksyon'),
        headers: [
          '#',
          t('Date', 'Petsa'),
          t('Time', 'Oras'),
          t('Tracking ID', 'Tracking ID'),
          t('Plate', 'Plaka'),
          t('Driver', 'Driver'),
          t('Fee', 'Bayad'),
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
        _queuePdfPopup(t('PDF sent to share sheet', 'Naipadala ang PDF'));
      }
    } catch (e) {
      if (mounted) {
        _queuePdfPopup(t("Couldn't export PDF: $e", 'Hindi na-export ang PDF: $e'),
            isError: true);
      }
    }
  }

  Future<void> _generateActivityPdf(
      List<AuditLog> logs, _AuditTab tab) async {
    try {
      final dateFmt = DateFormat('MMM d, yyyy');
      final timeFmt = DateFormat('hh:mm:ss a');
      // Computed straight from [logs], not read off the currently
      // rendered sort order (that sort can be by Event or Actor, not
      // date) — earliest/latest here always reflect the real span of
      // what's in the export regardless of which column it's sorted by.
      final timestamps = logs.map((l) => l.timestamp).toList();
      final earliest = timestamps.reduce((a, b) => a.isBefore(b) ? a : b);
      final latest = timestamps.reduce((a, b) => a.isAfter(b) ? a : b);
      final dateRange = dateFmt.format(earliest) == dateFmt.format(latest)
          ? dateFmt.format(earliest)
          : '${dateFmt.format(earliest)} - ${dateFmt.format(latest)}';
      final actorCount = logs.map(_actorDisplay).toSet().length;
      await PdfExportService.exportTable(
        title: tab == _AuditTab.access
            ? t('Access log', 'Access Log')
            : t('Activity log', 'Activity Log'),
        headers: [
          '#',
          t('Date', 'Petsa'),
          t('Time', 'Oras'),
          t('Event', 'Pangyayari'),
          t('Actor', 'Gumawa'),
        ],
        rows: [
          for (var i = 0; i < logs.length; i++)
            [
              '${i + 1}',
              dateFmt.format(logs[i].timestamp),
              timeFmt.format(logs[i].timestamp),
              logs[i].description,
              _actorDisplay(logs[i]),
            ],
        ],
        summary: [
          MapEntry(t('Total events', 'Kabuuang Pangyayari'), '${logs.length}'),
          MapEntry(t('Date range', 'Saklaw ng Petsa'), dateRange),
          MapEntry(t('Actors involved', 'Mga Kasangkot'), '$actorCount'),
        ],
      );
      if (mounted) {
        _queuePdfPopup(t('PDF sent to share sheet', 'Naipadala ang PDF'));
      }
    } catch (e) {
      if (mounted) {
        _queuePdfPopup(t("Couldn't export PDF: $e", 'Hindi na-export ang PDF: $e'),
            isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Audit Trail', 'Talaan ng Aktibidad'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            key: _pdfButtonKey,
            tooltip: t('Export PDF', 'I-export bilang PDF'),
            onPressed: _exportPdf,
            icon: const Icon(Icons.picture_as_pdf_rounded),
          ),
        ],
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
                child: _Segmented(
                  tab: _tab,
                  onChanged: (v) => setState(() => _tab = v),
                ),
              ),
              Expanded(
                // Entries embeds the exact same live Transaction logs
                // view (search, All/Today/Last hour, every transaction
                // ever logged) rather than a derived audit-log summary —
                // for real transparency this has to be the one true list,
                // not a second copy that could drift from it.
                child: _tab == _AuditTab.entries
                    ? TransactionLogView(key: _entriesKey)
                    : StreamBuilder<List<AuditLog>>(
                        stream: _auditLogs,
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return Center(
                                child: CircularProgressIndicator(
                                    color: YosColors.ink));
                          }
                          final logs = snap.data!
                              .where((l) => _tab == _AuditTab.access
                                  ? _accessActions.contains(l.actionType)
                                  // Everything else, minus transaction
                                  // entries — those live on their own
                                  // tab now (see above) instead of
                                  // cluttering general activity.
                                  : !_accessActions.contains(l.actionType) &&
                                      !_transactionActions
                                          .contains(l.actionType))
                              .toList()
                            ..sort(_compare);
                          _visibleLogs = logs;

                          if (logs.isEmpty) {
                            return Center(
                              child: Text(
                                _tab == _AuditTab.access
                                    ? t('No sign-in events yet.',
                                        'Wala pang sign-in events.')
                                    : t('No activity recorded yet.',
                                        'Wala pang naitalang aktibidad.'),
                                style: TextStyle(
                                    color: YosColors.sub,
                                    fontWeight: FontWeight.w600),
                              ),
                            );
                          }
                          return _AuditTable(
                            logs: logs,
                            sortColumnIndex: _sortColumnIndex,
                            sortAscending: _sortAscending,
                            onSort: _onSort,
                            style: _style,
                            actorDisplay: _actorDisplay,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Spreadsheet-style view of the audit log — sortable Date/Time/Event/Actor
/// columns, tap a header to sort (tap again to flip direction), same as an
/// Excel column sort.
class _AuditTable extends StatelessWidget {
  const _AuditTable({
    required this.logs,
    required this.sortColumnIndex,
    required this.sortAscending,
    required this.onSort,
    required this.style,
    required this.actorDisplay,
  });

  final List<AuditLog> logs;
  final int sortColumnIndex;
  final bool sortAscending;
  final void Function(int columnIndex, bool ascending) onSort;
  final (IconData, Color) Function(String action) style;
  final String Function(AuditLog log) actorDisplay;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('MMM d, yyyy');
    final timeFmt = DateFormat('hh:mm:ss a');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Container(
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration:
            const BoxDecoration(), // no card fill — sits on the page canvas
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              sortColumnIndex: sortColumnIndex,
              sortAscending: sortAscending,
              // Rows are tappable (see onSelectChanged below) without
              // turning this into a multi-select table — no checkbox
              // column, just a per-row tap opening that entry's own detail
              // dialog. The horizontal-scroll table itself is untouched:
              // this is an addition for anyone who'd rather tap a row than
              // drag to see its Event/Actor columns, not a replacement.
              showCheckboxColumn: false,
              // Explicit transparent, not left null: Material's DataTable
              // otherwise paints its own default row surface underneath
              // (a flat white/near-white fill regardless of this
              // Container no longer providing one), which is exactly the
              // white background this was meant to remove.
              dataRowColor: WidgetStateProperty.all(Colors.transparent),
              headingRowColor: WidgetStateProperty.all(YosColors.surfaceHigh),
              headingTextStyle: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  color: YosColors.ink),
              dataTextStyle: TextStyle(fontSize: 13, color: YosColors.ink),
              columnSpacing: 28,
              columns: [
                const DataColumn(label: Text('#')),
                const DataColumn(
                    label: Icon(Icons.cloud_sync_rounded, size: 16)),
                DataColumn(label: Text(t('Date', 'Petsa')), onSort: onSort),
                DataColumn(label: Text(t('Time', 'Oras')), onSort: onSort),
                DataColumn(
                    label: Text(t('Event', 'Pangyayari')), onSort: onSort),
                DataColumn(label: Text(t('Actor', 'Gumawa')), onSort: onSort),
              ],
              rows: [
                for (var i = 0; i < logs.length; i++)
                  DataRow(
                    onSelectChanged: (_) => showDialog<void>(
                      context: context,
                      builder: (_) => _AuditLogDetailDialog(
                        log: logs[i],
                        style: style,
                        actorDisplay: actorDisplay,
                      ),
                    ),
                    cells: [
                      DataCell(Text('${i + 1}',
                          style: TextStyle(
                              color: YosColors.sub,
                              fontWeight: FontWeight.w600))),
                      DataCell(logs[i].pendingSync
                          ? const Icon(Icons.schedule_rounded,
                              size: 15, color: YosColors.warn)
                          : const Icon(Icons.check_circle_rounded,
                              size: 15, color: YosColors.good)),
                      DataCell(Text(dateFmt.format(logs[i].timestamp))),
                      DataCell(Text(timeFmt.format(logs[i].timestamp))),
                      DataCell(_EventCell(log: logs[i], style: style)),
                      DataCell(Text(actorDisplay(logs[i]),
                          overflow: TextOverflow.ellipsis)),
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

/// Full detail popup for one [AuditLog] row — reached by tapping the row
/// (see [_AuditTable]'s onSelectChanged) as an alternative to dragging the
/// table horizontally to see its Event/Actor columns. Read-only: nothing
/// here is editable, so the header's ✕ is the only way out, same as
/// FeesScreen's own read-only rate-history dialog.
class _AuditLogDetailDialog extends StatelessWidget {
  const _AuditLogDetailDialog({
    required this.log,
    required this.style,
    required this.actorDisplay,
  });

  final AuditLog log;
  final (IconData, Color) Function(String action) style;
  final String Function(AuditLog log) actorDisplay;

  @override
  Widget build(BuildContext context) {
    final (icon, badgeColor) = style(log.actionType);
    final dateFmt = DateFormat('MMM d, y');
    final timeFmt = DateFormat('hh:mm:ss a');
    final hasDelta = log.previousValue != null && log.newValue != null;

    return Dialog(
      backgroundColor: YosColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(t('Audit entry', 'Audit Entry'),
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
                _AuditDetailRow(
                  icon: icon,
                  badgeColor: badgeColor,
                  label: t('Event', 'Pangyayari'),
                  value: log.description,
                ),
                _AuditDetailRow(
                  icon: Icons.calendar_today_rounded,
                  label: t('Date', 'Petsa'),
                  value: dateFmt.format(log.timestamp),
                ),
                _AuditDetailRow(
                  icon: Icons.schedule_rounded,
                  label: t('Time', 'Oras'),
                  value: timeFmt.format(log.timestamp),
                ),
                _AuditDetailRow(
                  icon: Icons.person_rounded,
                  label: t('Actor', 'Gumawa'),
                  value: actorDisplay(log),
                ),
                if (hasDelta)
                  _AuditDetailRow(
                    icon: Icons.swap_horiz_rounded,
                    label: t('Change', 'Pagbabago'),
                    // A peso sign for a fee change, bare otherwise (points
                    // deltas already read fine unitless) — formatPoints
                    // alone left a fee's before/after looking like an
                    // unlabeled points count instead of a price.
                    value: log.actionType == AuditAction.feeUpdated
                        ? '₱${formatPoints(log.previousValue!)} → '
                            '₱${formatPoints(log.newValue!)}'
                        : '${formatPoints(log.previousValue!)} → '
                            '${formatPoints(log.newValue!)}',
                  ),
                _AuditDetailRow(
                  icon: log.pendingSync
                      ? Icons.schedule_rounded
                      : Icons.check_circle_rounded,
                  label: t('Sync status', 'Katayuan ng Sync'),
                  value: log.pendingSync
                      ? t('Pending sync', 'Naghihintay mag-sync')
                      : t('Synced', 'Na-sync na'),
                  valueColor: log.pendingSync ? YosColors.warn : YosColors.good,
                  isLast: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One icon-badge + label/value row inside [_AuditLogDetailDialog] — same
/// shape as LogsScreen's own transaction-detail row, plus an optional
/// per-row [badgeColor] so the Event row can use that action's own color
/// (see [_style]) instead of the default accentSoft badge every other row
/// uses.
class _AuditDetailRow extends StatelessWidget {
  const _AuditDetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.badgeColor,
    this.valueColor,
    this.isLast = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? badgeColor;
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
                color: badgeColor ?? YosColors.accentSoft,
                borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            // accentDeep on every badge, not just the plain-accentSoft
            // ones — a flat YosColors.ink icon on the Event row's own
            // pastel (mint/badSoft/etc.) read visibly heavier/darker than
            // the same icon elsewhere in this dialog; one consistent icon
            // color across every row fixes that regardless of which badge
            // color is underneath it.
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
                    maxLines: 3,
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

class _EventCell extends StatelessWidget {
  const _EventCell({required this.log, required this.style});
  final AuditLog log;
  final (IconData, Color) Function(String action) style;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = style(log.actionType);
    final failed = log.actionType == AuditAction.loginFailed ||
        log.actionType == AuditAction.faceLoginFailed;
    final hasDelta = log.previousValue != null && log.newValue != null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 14, color: YosColors.ink),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(log.description,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: failed ? YosColors.bad : YosColors.ink)),
                // The exact before/after this action recorded — a
                // compliance record needs the actual values, not just a
                // free-text summary of what changed.
                if (hasDelta)
                  Text(
                      '${formatPoints(log.previousValue!)} → '
                      '${formatPoints(log.newValue!)}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: YosColors.sub,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.tab, required this.onChanged});
  final _AuditTab tab;
  final ValueChanged<_AuditTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: YosColors.surface,
        borderRadius: BorderRadius.circular(999),
        boxShadow: kSoftShadow,
      ),
      child: Row(
        children: [
          _tab(t('Activity', 'Aktibidad'), Icons.timeline_rounded,
              tab == _AuditTab.activity, () => onChanged(_AuditTab.activity)),
          _tab(t('Access', 'Access'), Icons.vpn_key_rounded,
              tab == _AuditTab.access, () => onChanged(_AuditTab.access)),
          _tab(t('Entries', 'Mga Entry'), Icons.receipt_long_rounded,
              tab == _AuditTab.entries, () => onChanged(_AuditTab.entries)),
        ],
      ),
    );
  }

  Widget _tab(String label, IconData icon, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          decoration: BoxDecoration(
            // accentDeep, not YosColors.ink or plain accent — a solid,
            // always-consistent active fill regardless of dark mode. The
            // label/icon on top use YosColors.onAccent rather than a
            // fixed color, so this keeps working if a future palette's
            // accentDeep isn't bright in both modes — see onAccent's own
            // comment.
            color: active ? YosColors.accentDeep : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          // Three segments now instead of two, so each gets noticeably
          // less width — Flexible + ellipsis keeps a long label from
          // overflowing this pill on a narrow phone or a bumped-up
          // accessibility text scale.
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 17, color: active ? YosColors.onAccent : YosColors.sub),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: active ? YosColors.onAccent : YosColors.sub)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
