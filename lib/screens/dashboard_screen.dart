import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/access_request.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/registry_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/mini_charts.dart';
import '../widgets/odometer_counter.dart';
import '../widgets/reset_password_dialog.dart';
import '../widgets/toast.dart';
import 'access_requests_screen.dart';
import 'audit_screen.dart';
import 'fees_screen.dart';
import 'logs_screen.dart';
import 'registry_screen.dart';
import 'rfid_points_screen.dart';
import 'vehicle_entry_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final repo = YosRepository.instance;
  bool _isAdmin = false;
  List<AccessRequest> _pendingRequests = const [];
  StreamSubscription<bool>? _adminSub;
  StreamSubscription<List<AccessRequest>>? _requestsSub;

  // RFID tap-to-receipt, right from the dashboard — no need to open Print
  // receipt first. The _rfid field/focus catches a directly-connected
  // reader's keystrokes (same HID pattern as VehicleEntryScreen).
  final _rfid = TextEditingController();
  final _rfidFocus = FocusNode();

  /// True from the moment a tag resolves to a match until its receipt
  /// sheet closes — blocks a second scan from opening a second sheet (or
  /// double-writing a transaction) while the first one is still being
  /// confirmed/printed. See _onRfidScanned.
  bool _receiptBusy = false;

  // A day that's already over never changes, so this is fetched once
  // rather than kept live — powers the collections card's "vs yesterday"
  // comparison. Null until it loads; the card falls back to a plain
  // "waiting to sync" line in that window instead of a misleading 0%.
  double? _yesterdayRevenue;

  // Grabbed exactly once, not called fresh inside build() — this screen
  // rebuilds often (admin status, sync status, pending requests), and
  // handing StreamBuilder a brand-new Stream instance on every one of
  // those rebuilds is exactly what causes Flutter's
  // "'_dependents.isEmpty': is not true" crash, most visible right after
  // an unrelated action (e.g. an admin saving a fee edit) happens to
  // land a rebuild at the wrong moment. Same `late final` pattern
  // FeesScreen, ProfileScreen, and RfidPointsScreen already use for their
  // own streams.
  late final Stream<List<ParkingTransaction>> _todayTx = repo.todayTransactions();

  @override
  void initState() {
    super.initState();
    repo.addListener(_onChange);
    repo.yesterdayRevenue().then((v) {
      if (mounted) setState(() => _yesterdayRevenue = v);
    });
    _adminSub = repo.currentUserIsAdmin.listen(
      (v) {
        if (mounted) setState(() => _isAdmin = v);
        // Only admins can read access_requests (see firestore.rules) —
        // start or stop listening in step with admin status instead of
        // always subscribing and letting a non-admin's read fail.
        _requestsSub?.cancel();
        _requestsSub = v
            ? repo.pendingAccessRequests().listen(
                (list) {
                  if (mounted) setState(() => _pendingRequests = list);
                },
                onError: (Object e) => debugPrint(
                    'pendingAccessRequests stream error (ignored): $e'),
              )
            : null;
        if (!v && mounted) setState(() => _pendingRequests = const []);
      },
      // Dashboard mounts immediately inside RootShell's IndexedStack,
      // including right after a brand-new sign-in — the underlying read
      // can transiently hit a permission-denied before Firestore
      // recognizes the just-minted auth token (same race
      // markFaceIdEnrolled/collectorExists already retry for elsewhere).
      // An unhandled stream error here would surface as an uncaught
      // exception (a red screen) instead of the harmless, self-
      // recovering blip it actually is.
      onError: (Object e) =>
          debugPrint('currentUserIsAdmin stream error (ignored): $e'),
    );
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    repo.removeListener(_onChange);
    _adminSub?.cancel();
    _requestsSub?.cancel();
    _rfid.dispose();
    _rfidFocus.dispose();
    super.dispose();
  }

  /// Same lookup-and-open-receipt flow as VehicleEntryScreen._onRfidScanned
  /// — kept here too so a tap works straight from the dashboard for a
  /// Collector. Admin's job here is oversight/editing (fees, points rate,
  /// collectors), never the day-to-day scan/log/print work, so this bails
  /// out for an admin session even though the capture field below is
  /// already never built for one — a defensive second guard, not the only
  /// one.
  Future<void> _onRfidScanned(String raw) async {
    final tag = raw.trim();
    _rfid.clear();
    if (tag.isEmpty || _isAdmin) return;
    if (_receiptBusy) {
      Toast.warn(context, 'Finish the current receipt first.');
      return;
    }
    _receiptBusy = true;
    try {
      final match = await VehicleRegistry.instance.lookupByRfid(tag);
      if (!mounted) return;
      if (match == null) {
        Toast.error(context, 'No vehicle enrolled with tag "$tag".');
        _rfidFocus.requestFocus();
        return;
      }
      final type = VehicleType.fromLabel(match.vehicleType);
      final tx = YosRepository.instance.buildTransaction(
        driverName: match.driverName,
        plateNumber: match.plateNumber,
        type: type,
        zoneId: match.defaultZoneId,
      );
      HapticFeedback.heavyImpact();
      Toast.success(context,
          '${match.plateNumber} · ${match.driverName} · ₱${tx.fee.toStringAsFixed(0)}');
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ReceiptPreviewDrawer(
          tx: tx,
          registered: match,
          onDone: () => Navigator.of(context).pop(),
        ),
      );
      if (mounted) _rfidFocus.requestFocus();
    } finally {
      _receiptBusy = false;
    }
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<List<ParkingTransaction>>(
            stream: _todayTx,
            builder: (context, snap) {
              final txs = snap.data ?? const <ParkingTransaction>[];
              final pending = txs.where((t) => t.pendingSync).length;
              final revenue = txs.fold<double>(0, (s, t) => s + t.fee);
              const goal = 60;
              final ringVal = (txs.length / goal).clamp(0.0, 1.0);

              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  PopIn(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final narrow = c.maxWidth < 600;
                        final tiny = c.maxWidth < 340;

                        final titleBlock = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(_greeting(),
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(
                                      color: YosColors.sub,
                                      fontSize: tiny ? 13 : 15,
                                      fontWeight: FontWeight.w600)),
                            ),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(_isAdmin ? 'Admin' : 'Collector',
                                  maxLines: 1,
                                  softWrap: false,
                                  style: text.headlineMedium
                                      ?.copyWith(fontSize: tiny ? 26 : 30)),
                            ),
                          ],
                        );

                        // Printer, Collectors, Change Password, and Log
                        // out all moved into their own bottom-nav tabs/
                        // actions (see RootShell) — nothing here opens
                        // them anymore. Header chips stay reserved for
                        // things that need at-a-glance visibility (sync
                        // status) or an active notification (pending
                        // access requests).
                        final chips = <Widget>[
                          if (_isAdmin && _pendingRequests.isNotEmpty)
                            _AccessRequestsChip(
                              count: _pendingRequests.length,
                              onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AccessRequestsScreen())),
                            ),
                          SyncBadge(
                              online: repo.online, pendingCount: pending),
                        ];

                        if (narrow) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              titleBlock,
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment:
                                    WrapCrossAlignment.center,
                                children: chips,
                              ),
                            ],
                          );
                        }

                        return Row(
                          children: [
                            Expanded(child: titleBlock),
                            const SizedBox(width: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: chips,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 22),

                  PopIn(
                    delayMs: 80,
                    child: _CollectionsCard(
                      revenue: revenue,
                      pending: pending,
                      yesterdayRevenue: _yesterdayRevenue,
                      barValues: _bucketTotals(txs, 8, (t) => t.fee),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // IntrinsicHeight: gives the Row a bounded height to
                  // stretch its children to (its natural cross-axis size
                  // here is unbounded, sitting directly in a ListView) —
                  // CrossAxisAlignment.stretch alone throws "BoxConstraints
                  // forces an infinite height" without it.
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: PopIn(
                            delayMs: 140,
                            child: _TransactionsCard(
                              count: txs.length,
                              ringValue: ringVal,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: PopIn(
                            delayMs: 200,
                            child: _AverageCard(
                              average: txs.isEmpty ? 0 : revenue / txs.length,
                              lineValues: _bucketAverages(txs, 8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isAdmin && _pendingRequests.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    PopIn(
                      delayMs: 220,
                      child: _PendingResetsCard(requests: _pendingRequests),
                    ),
                  ],
                  // Invisible RFID capture field — no visible "Tap RFID
                  // card" UI, but still autofocused and wired to
                  // _onRfidScanned so a directly-connected (OTG) reader's
                  // keystrokes are caught the same as at Vehicle Entry.
                  // Offstage keeps it out of layout/paint entirely while
                  // leaving focus/text-input untouched. Not readOnly: that
                  // would drop the platform text-input connection this
                  // needs to actually receive the reader's keystrokes on
                  // Android — keyboardType.none alone is enough to keep the
                  // on-screen keyboard from popping up. Not built at all
                  // for an admin session — scanning/logging/printing is
                  // Collector work; Admin's dashboard tiles already leave
                  // that whole path off (see _tiles), so this field
                  // shouldn't silently keep listening for it underneath.
                  if (!_isAdmin)
                    Offstage(
                      offstage: true,
                      child: TextField(
                        controller: _rfid,
                        focusNode: _rfidFocus,
                        autofocus: true,
                        keyboardType: TextInputType.none,
                        onSubmitted: _onRfidScanned,
                      ),
                    ),

                  const Padding(
                    padding: EdgeInsets.only(left: 4, bottom: 12),
                    child: Text('Quick actions',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 18)),
                  ),

                  LayoutBuilder(
                    builder: (context, c) {
                      // Below ~380 of content width, a 2-up tile only leaves
                      // ~70px for text next to the 44px icon — not enough
                      // room for "Transaction logs" to fit as one word-wrap-
                      // able line, so Flutter falls back to breaking the
                      // word itself (e.g. the trailing "n" of "Transaction"
                      // wraps down alone). Dropping to a single column below
                      // that width gives tiles the full row to work with.
                      final cols = c.maxWidth < 380
                          ? 1
                          : c.maxWidth < 700
                              ? 2
                              : 3;
                      return GridView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        // A fixed pixel height instead of childAspectRatio:
                        // the tile's content (icon beside one line of text) has
                        // a fixed height regardless of screen width, so tying
                        // height to width (aspect ratio) made the cards balloon
                        // on wider screens even though the content inside
                        // stayed the same size, leaving a lot of empty space.
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          mainAxisExtent: 78,
                        ),
                        children: _tiles(context)
                            .asMap()
                            .entries
                            .map((e) => PopIn(
                                  delayMs: 240 + e.key * 50,
                                  child: e.value,
                                ))
                            .toList(),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // Registered vehicles and Print receipt are collector-only work — an
  // admin doesn't do day-to-day collection, so those two stay off the
  // admin dashboard's quick actions. Everything else here is reporting/
  // oversight, relevant to both roles.
  List<Widget> _tiles(BuildContext context) => [
        _NavTile(
          color: YosColors.mint,
          icon: Icons.receipt_long_rounded,
          title: 'Transaction logs',
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const LogsScreen())),
        ),
        _NavTile(
          color: YosColors.mint,
          icon: Icons.request_quote_rounded,
          title: 'Fee matrix',
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const FeesScreen())),
        ),
        _NavTile(
          color: YosColors.mint,
          icon: Icons.security_rounded,
          title: 'Audit trail',
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const AuditScreen())),
        ),
        if (!_isAdmin)
          _NavTile(
            color: YosColors.mint,
            icon: Icons.directions_car_filled_rounded,
            title: 'Registered vehicles',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RegistryScreen())),
          ),
        _NavTile(
          color: YosColors.mint,
          icon: Icons.loyalty_rounded,
          title: 'RFID points',
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RfidPointsScreen())),
        ),
        if (!_isAdmin)
          _NavTile(
            color: YosColors.mint,
            icon: Icons.receipt_rounded,
            title: 'Print receipt',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const VehicleEntryScreen())),
          ),
      ];
}

/// Sums [valueOf] per time bucket across today so far (midnight to now),
/// evenly split into [buckets] slices — the raw series behind
/// [_CollectionsCard]'s bar sparkline. A slice with no transactions yet
/// (e.g. every slice past the current time) is just 0; [BarSparkline]
/// renders that as a short stub rather than nothing.
List<double> _bucketTotals(
  List<ParkingTransaction> txs,
  int buckets,
  double Function(ParkingTransaction) valueOf,
) {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  final totalMinutes = now.difference(start).inMinutes.clamp(1, 24 * 60);
  final bucketMinutes = totalMinutes / buckets;
  final sums = List<double>.filled(buckets, 0);
  for (final t in txs) {
    final minutesSinceStart = t.timestamp.difference(start).inMinutes;
    final idx =
        (minutesSinceStart / bucketMinutes).floor().clamp(0, buckets - 1);
    sums[idx] += valueOf(t);
  }
  return sums;
}

/// Same bucketing as [_bucketTotals], but the average fee per bucket
/// rather than a sum — the series behind [_AverageCard]'s trend line. An
/// empty bucket forward-fills the last known average instead of dropping
/// to 0, since 0 would read as "average fee was zero" rather than "no
/// transactions yet in this slice".
List<double> _bucketAverages(List<ParkingTransaction> txs, int buckets) {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  final totalMinutes = now.difference(start).inMinutes.clamp(1, 24 * 60);
  final bucketMinutes = totalMinutes / buckets;
  final sums = List<double>.filled(buckets, 0);
  final counts = List<int>.filled(buckets, 0);
  for (final t in txs) {
    final minutesSinceStart = t.timestamp.difference(start).inMinutes;
    final idx =
        (minutesSinceStart / bucketMinutes).floor().clamp(0, buckets - 1);
    sums[idx] += t.fee;
    counts[idx]++;
  }
  var last = 0.0;
  return [
    for (var i = 0; i < buckets; i++)
      if (counts[i] > 0) (last = sums[i] / counts[i]) else last,
  ];
}

/// Dashboard's headline stat — today's total collections, how that
/// compares to yesterday, and a bar sparkline of the day's pace so far.
/// Placed right under the header's [SyncBadge] ("All synced" / "Syncing
/// N"), which is why the sync-pending count isn't repeated here.
class _CollectionsCard extends StatelessWidget {
  const _CollectionsCard({
    required this.revenue,
    required this.pending,
    required this.yesterdayRevenue,
    required this.barValues,
  });

  final double revenue;
  final int pending;
  final double? yesterdayRevenue;
  final List<double> barValues;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final money = NumberFormat.currency(symbol: '₱', decimalDigits: 0);
    final yesterday = yesterdayRevenue;
    final pctChange = (yesterday == null || yesterday <= 0)
        ? null
        : (revenue - yesterday) / yesterday * 100;

    return GlassCard(
      color: YosColors.mint,
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Today's collections",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: YosColors.sub,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: OdometerCounter(
                    value: money.format(revenue),
                    style: text.displayLarge?.copyWith(fontSize: 34),
                  ),
                ),
                const SizedBox(height: 8),
                if (pctChange != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        pctChange >= 0
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 14,
                        color: pctChange >= 0 ? YosColors.good : YosColors.bad,
                      ),
                      const SizedBox(width: 2),
                      Text('${pctChange.abs().toStringAsFixed(1)}%',
                          style: TextStyle(
                              color: pctChange >= 0
                                  ? YosColors.good
                                  : YosColors.bad,
                              fontWeight: FontWeight.w800,
                              fontSize: 12)),
                      const SizedBox(width: 4),
                      const Text('vs yesterday',
                          style: TextStyle(
                              color: YosColors.sub,
                              fontWeight: FontWeight.w600,
                              fontSize: 12)),
                    ],
                  )
                else
                  Text(
                      pending > 0
                          ? '$pending waiting to sync'
                          : 'No data for yesterday yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: YosColors.sub,
                          fontWeight: FontWeight.w600,
                          fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          BarSparkline(
            values: barValues,
            color: YosColors.ink,
            highlightColor: YosColors.accent,
            width: 90,
            height: 56,
          ),
        ],
      ),
    );
  }
}

/// Today's transaction count, with a small goal-progress ring on the side
/// (same [ProgressRing]/goal the header's collections card used to show
/// inline) — the ring's label just reads "Today" now that the count
/// itself is the card's headline number.
class _TransactionsCard extends StatelessWidget {
  const _TransactionsCard({required this.count, required this.ringValue});

  final int count;
  final double ringValue;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassCard(
      color: YosColors.mint,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Transactions',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: YosColors.sub,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: OdometerCounter(
                    value: '$count',
                    style: text.displayLarge?.copyWith(fontSize: 30),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ProgressRing(
                value: ringValue,
                size: 48,
                stroke: 5,
                color: YosColors.accent,
                track: const Color(0x1F16161A),
                child: const Text('Today',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        color: YosColors.ink)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Average fee per transaction today, with a line sparkline of how that
/// average has trended across the day (see [_bucketAverages]).
class _AverageCard extends StatelessWidget {
  const _AverageCard({required this.average, required this.lineValues});

  final double average;
  final List<double> lineValues;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final money = NumberFormat.currency(symbol: '₱', decimalDigits: 0);
    return GlassCard(
      color: YosColors.moss,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Average',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: YosColors.sub,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: OdometerCounter(
              value: money.format(average),
              style: text.displayLarge?.copyWith(fontSize: 30),
            ),
          ),
          const SizedBox(height: 10),
          LineSparkline(
            values: lineValues,
            color: YosColors.accentDeep,
            width: double.infinity,
            height: 28,
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.color,
    required this.icon,
    required this.title,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: YosColors.ink, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// Dashboard-level notification listing each collector who's filed a
/// "help me back in" ping (see AccessRequest), with a "Reset password"
/// button right on the name — no need to open the full Access requests
/// list first for the common case. Shares the exact same
/// pick-collector-then-reset flow as that screen (see
/// grantAccessRequestReset) since a typed request name still isn't a
/// verified identity on its own.
class _PendingResetsCard extends StatelessWidget {
  const _PendingResetsCard({required this.requests});
  final List<AccessRequest> requests;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      color: YosColors.moss,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.notifications_active_rounded,
                  color: YosColors.warn, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    requests.length == 1
                        ? '1 collector needs a password reset'
                        : '${requests.length} collectors need a password reset',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final r in requests)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        r.name.isEmpty ? '(no name given)' : r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => grantAccessRequestReset(context, r),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Reset password',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AccessRequestsChip extends StatelessWidget {
  const _AccessRequestsChip({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: YosColors.warn,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.notifications_active_rounded,
                size: 15, color: Colors.white),
            const SizedBox(width: 6),
            Text('$count request${count == 1 ? '' : 's'}',
                maxLines: 1,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

