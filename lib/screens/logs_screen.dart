import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../widgets/glow_effects.dart';

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
        title: const Text('Transaction logs',
            style: TextStyle(fontWeight: FontWeight.w800)),
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Column(
            children: [
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Plate, receipt ID, or driver…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Clear search',
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
                    (_TimeFilter.all, 'All'),
                    (_TimeFilter.today, 'Today'),
                    (_TimeFilter.hour, 'Last hour'),
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
                        const Icon(Icons.inbox_rounded,
                            size: 56, color: YosColors.sub),
                        const SizedBox(height: 12),
                        Text(
                          _search.text.isEmpty
                              ? 'No entries yet.\nLog a vehicle to start.'
                              : 'No matches.\nTry a different plate or ID.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
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
        ? ('SYNCING', YosColors.warn)
        : ('PAID', YosColors.good);

    // A read-only row — no InkWell/haptic here, unlike _RegCard: there's
    // no detail screen to navigate to, and giving it tap feedback it
    // doesn't act on would be a false affordance.
    return MergeSemantics(
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: YosColors.sub.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${index + 1}',
                      style: const TextStyle(
                          color: YosColors.sub,
                          fontWeight: FontWeight.w800,
                          fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('#${tx.trackingId}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          letterSpacing: 0.4)),
                ),
                const Spacer(),
                if (tx.printed)
                  const Padding(
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
                style: const TextStyle(
                    color: YosColors.sub,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(date,
                    style: const TextStyle(
                        color: YosColors.sub,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const Spacer(),
                Text('₱${tx.fee.toStringAsFixed(0)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
              ],
            ),
          ],
        ),
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
            const Icon(Icons.cloud_off_rounded,
                size: 56, color: YosColors.sub),
            const SizedBox(height: 16),
            const Text(
              "Couldn't load transaction logs.",
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: YosColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 17),
            ),
            const SizedBox(height: 6),
            const Text(
              'Check your connection — this list updates automatically '
              'once you\'re back online.',
              textAlign: TextAlign.center,
              style: TextStyle(color: YosColors.sub, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}
