import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/points_settings_service.dart' show formatPoints;
import '../widgets/glow_effects.dart';
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

class _AuditScreenState extends State<AuditScreen> {
  _AuditTab _tab = _AuditTab.activity;

  // Grabbed once, not called fresh inside build() — sorting/tab-switching
  // both call setState here, which would otherwise hand StreamBuilder a
  // brand-new Stream instance every time, the exact trigger for Flutter's
  // "'_dependents.isEmpty': is not true" crash. Same `late final` pattern
  // used across the other screens with a live Firestore stream.
  late final Stream<List<AuditLog>> _auditLogs =
      YosRepository.instance.auditLogs();

  // Column indices into the DataTable below: 2 = Date, 3 = Time,
  // 4 = Event, 5 = Actor. Columns 0 (row #) and 1 (sync status) aren't
  // sortable — row # always just reflects whatever order the rest of the
  // sort produced.
  int _sortColumnIndex = 2;
  bool _sortAscending = false; // newest first by default

  int _compare(AuditLog a, AuditLog b) {
    final cmp = switch (_sortColumnIndex) {
      2 || 3 => a.timestamp.compareTo(b.timestamp),
      4 => a.description.compareTo(b.description),
      5 => a.actorId.compareTo(b.actorId),
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
        AuditAction.loginFailed => (
            Icons.gpp_bad_rounded,
            const Color(0xFFFBE8E6)
          ),
        AuditAction.register => (Icons.person_add_rounded, YosColors.mint),
        AuditAction.faceEnroll => (
            Icons.face_retouching_natural,
            YosColors.seafoam
          ),
        AuditAction.faceIdRemoved => (
            Icons.no_accounts_rounded,
            const Color(0xFFFBE8E6)
          ),
        AuditAction.faceLoginSuccess => (
            Icons.face_retouching_natural,
            YosColors.mint
          ),
        AuditAction.faceLoginFailed => (
            Icons.gpp_bad_rounded,
            const Color(0xFFFBE8E6)
          ),
        AuditAction.newEntry => (Icons.add_road_rounded, YosColors.mint),
        AuditAction.search => (Icons.search_rounded, YosColors.seafoam),
        AuditAction.syncOnline => (Icons.cloud_done_rounded, YosColors.mint),
        AuditAction.syncOffline => (
            Icons.cloud_off_rounded,
            YosColors.pistachio
          ),
        AuditAction.backup => (Icons.save_rounded, YosColors.sage),
        AuditAction.printReceipt => (Icons.print_rounded, YosColors.moss),
        AuditAction.pointsEarned => (Icons.loyalty_rounded, YosColors.mint),
        AuditAction.pointsRedeemed => (
            Icons.redeem_rounded,
            YosColors.seafoam
          ),
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
            const Color(0xFFFDECD1)
          ),
        _ => (Icons.circle_outlined, YosColors.seafoam),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Audit trail',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
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
                    ? const TransactionLogView()
                    : StreamBuilder<List<AuditLog>>(
                        stream: _auditLogs,
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return const Center(
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

                          if (logs.isEmpty) {
                            return Center(
                              child: Text(
                                _tab == _AuditTab.access
                                    ? 'No sign-in events yet.'
                                    : 'No activity recorded yet.',
                                style: const TextStyle(
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
  });

  final List<AuditLog> logs;
  final int sortColumnIndex;
  final bool sortAscending;
  final void Function(int columnIndex, bool ascending) onSort;
  final (IconData, Color) Function(String action) style;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('MMM d, yyyy');
    final timeFmt = DateFormat('hh:mm:ss a');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: kSoftShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              sortColumnIndex: sortColumnIndex,
              sortAscending: sortAscending,
              headingRowColor:
                  WidgetStateProperty.all(YosColors.surfaceHigh),
              headingTextStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  color: YosColors.ink),
              dataTextStyle:
                  const TextStyle(fontSize: 13, color: YosColors.ink),
              columnSpacing: 28,
              columns: [
                const DataColumn(label: Text('#')),
                const DataColumn(
                    label: Icon(Icons.cloud_sync_rounded, size: 16)),
                DataColumn(label: const Text('Date'), onSort: onSort),
                DataColumn(label: const Text('Time'), onSort: onSort),
                DataColumn(label: const Text('Event'), onSort: onSort),
                DataColumn(label: const Text('Actor'), onSort: onSort),
              ],
              rows: [
                for (var i = 0; i < logs.length; i++)
                  DataRow(
                    cells: [
                      DataCell(Text('${i + 1}',
                          style: const TextStyle(
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
                      DataCell(Text(logs[i].actorId,
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
            decoration:
                BoxDecoration(color: color, borderRadius: BorderRadius.circular(9)),
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
                      style: const TextStyle(
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        boxShadow: kSoftShadow,
      ),
      child: Row(
        children: [
          _tab('Activity', Icons.timeline_rounded, tab == _AuditTab.activity,
              () => onChanged(_AuditTab.activity)),
          _tab('Access', Icons.vpn_key_rounded, tab == _AuditTab.access,
              () => onChanged(_AuditTab.access)),
          _tab('Entries', Icons.receipt_long_rounded,
              tab == _AuditTab.entries, () => onChanged(_AuditTab.entries)),
        ],
      ),
    );
  }

  Widget _tab(
      String label, IconData icon, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
              horizontal: 4, vertical: 12),
          decoration: BoxDecoration(
            color: active ? YosColors.ink : Colors.transparent,
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
                  size: 17,
                  color: active ? Colors.white : YosColors.sub),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: active ? Colors.white : YosColors.sub)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
