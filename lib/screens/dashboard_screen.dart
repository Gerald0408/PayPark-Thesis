import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/roles.dart';
import '../core/theme.dart';
import '../core/names.dart';
import '../models/access_request.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/odometer_counter.dart';
import '../widgets/reset_password_dialog.dart';
import '../widgets/visit_flow.dart';
import 'audit_screen.dart';
import 'blotter_screen.dart';
import 'error_logs_screen.dart';
import 'fees_screen.dart';
import 'logs_screen.dart';
import 'notifications_screen.dart';
import 'registry_screen.dart';
import 'reports_screen.dart';
import 'rfid_points_screen.dart';
import 'rfid_scan_screen.dart';
import 'vehicle_entry_screen.dart';

// NOTE: This file was accidentally overwritten with placeholder content
// during development and has been reconstructed from the original commit,
// everything read from it earlier in the same session, and cross-checks
// against sibling files (firestore_service.dart's transactionsForDate,
// vehicle_entry_screen.dart's confirmVehicleTypeOverride call) that were
// never touched by the overwrite. Most of this file is a verified,
// faithful rebuild — the one section rebuilt from inference rather than
// a direct read is [_CollectionsPager] (see its own doc comment below).
// Please give that one a look.

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.active = true});

  /// Whether this is RootShell's currently selected tab — used to hand
  /// focus back to the hidden RFID capture field on returning to it.
  final bool active;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  final repo = YosRepository.instance;
  bool _isAdmin = false;
  List<AccessRequest> _pendingRequests = const [];
  StreamSubscription<bool>? _adminSub;
  // Error Logs are the Super Admin's alone (technical, final control).
  bool _isSuperAdmin = false;
  StreamSubscription<bool>? _superSub;

  /// Whether currentUserIsAdmin has answered yet — until then the role
  /// (and so the app's color) isn't known, so an Admin doesn't flash teal.
  bool _adminKnown = false;

  /// Gives the whole app the signed-in role's colors (see
  /// YosColors.role): gold/navy Super Admin, blue Admin, teal Collector.
  void _applyRoleTheme() {
    if (!_adminKnown) return;
    final role = AppRole.of(isSuperAdmin: _isSuperAdmin, isAdmin: _isAdmin);
    YosColors.setRole(role.themeRole);
    if (role == AppRole.collector) {
      LocaleController.instance.preferForCollector();
    }
  }
  StreamSubscription<List<AccessRequest>>? _requestsSub;

  // Admin-only overstay alerts for the bell — see NotificationsScreen.
  // The timer re-counts every minute since overstay grows with the clock.
  List<ParkingTransaction> _parked = const [];
  StreamSubscription<List<ParkingTransaction>>? _parkedSub;
  Timer? _overstayTick;

  int get _overstayCount {
    final now = DateTime.now();
    return _parked.where((tx) => overstayOf(tx, now) != null).length;
  }

  // Pop-up reminders: a vehicle pops up the moment it overstays, then
  // again every [_remindEvery] until it's timed out (it drops out of
  // [_parked] then). Keyed by trackingId; one dialog at a time.
  static const _remindEvery = Duration(minutes: 30);
  final Map<String, DateTime> _lastAlerted = {};
  bool _alertOpen = false;

  void _checkOverstayAlerts() {
    if (_alertOpen || !mounted) return;
    final now = DateTime.now();
    final due = [
      for (final tx in _parked)
        if (overstayOf(tx, now) case final d?)
          if (_lastAlerted[tx.trackingId] == null ||
              now.difference(_lastAlerted[tx.trackingId]!) >= _remindEvery)
            (tx, d),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    if (due.isEmpty) return;
    for (final (tx, _) in due) {
      _lastAlerted[tx.trackingId] = now;
    }
    _alertOpen = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.timer_off_rounded, color: YosColors.bad),
        title: Text(t('Overstay Alert', 'Lumampas sa Oras'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (tx, d) in due.take(3))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                    t('${tx.plateNumber} · ${tx.vehicleType} — Over by ${formatStay(d)}',
                        '${tx.plateNumber} · ${tx.vehicleType} — Lampas ng ${formatStay(d)}'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            if (due.length > 3)
              Text(t('and ${due.length - 3} More', 'at ${due.length - 3} pa'),
                  style: TextStyle(color: YosColors.sub)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t('Later', 'Mamaya'))),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (due.length == 1) {
                runVisitFlow(context,
                    open: due.first.$1, prepareCheckIn: () async => null);
              } else {
                _open(NotificationsScreen(isAdmin: _isAdmin));
              }
            },
            child: Text(due.length == 1
                ? t('Time Out', 'Labas')
                : t('View All', 'Tingnan Lahat')),
          ),
        ],
      ),
    ).whenComplete(() => _alertOpen = false);
  }

  // RFID tap-to-receipt, right from the dashboard — no need to open Print
  // receipt first. The _rfid field/focus catches a directly-connected
  // reader's keystrokes (same HID pattern as VehicleEntryScreen).
  final _rfid = TextEditingController();
  final _rfidFocus = FocusNode();


  // Grabbed exactly once, not called fresh inside build() — this screen
  // rebuilds often (admin status, sync status, pending requests), and
  // handing StreamBuilder a brand-new Stream instance on every one of
  // those rebuilds is exactly what causes Flutter's
  // "'_dependents.isEmpty': is not true" crash, most visible right after
  // an unrelated action (e.g. an admin saving a fee edit) happens to
  // land a rebuild at the wrong moment. Same `late final` pattern
  // FeesScreen, ProfileScreen, and RfidPointsScreen already use for their
  // own streams.
  late final Stream<List<ParkingTransaction>> _todayTx =
      repo.todayTransactions();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    repo.addListener(_onChange);
    _superSub = repo.currentUserIsSuperAdmin.listen(
      (v) {
        if (mounted) setState(() => _isSuperAdmin = v);
        _applyRoleTheme();
      },
      onError: (Object e) =>
          debugPrint('currentUserIsSuperAdmin error (ignored): $e'),
    );
    _adminSub = repo.currentUserIsAdmin.listen(
      (v) {
        _adminKnown = true;
        if (mounted) setState(() => _isAdmin = v);
        _applyRoleTheme();
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
        // Overstay alerts go to admins and collectors alike — re-subscribed
        // here so a fresh sign-in's token is in place before the read.
        _parkedSub?.cancel();
        _overstayTick?.cancel();
        _parkedSub = repo.parkedVehicles().listen(
          (list) {
            if (!mounted) return;
            setState(() => _parked = list);
            _checkOverstayAlerts();
          },
          onError: (Object e) =>
              debugPrint('parkedVehicles stream error (ignored): $e'),
        );
        _overstayTick = Timer.periodic(const Duration(minutes: 1), (_) {
          if (!mounted) return;
          setState(() {});
          _checkOverstayAlerts();
        });
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
  void didUpdateWidget(DashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Back on the Home tab — e.g. from Printer, where connecting a
    // Bluetooth printer took focus away from the capture field.
    if (widget.active && !oldWidget.active) _reclaimRfidFocus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android's Bluetooth pairing/permission popups background the app
    // briefly, which can drop the capture field's text-input connection.
    if (state == AppLifecycleState.resumed) _reclaimRfidFocus();
  }

  /// Re-attaches the hidden RFID capture field so the next card tap reaches
  /// [_onRfidScanned]. Unfocus-then-refocus rather than a bare
  /// requestFocus: Flutter can still consider the field focused after
  /// Android has dropped its input connection, and requestFocus on an
  /// already-focused node is a no-op that wouldn't reconnect it.
  void _reclaimRfidFocus() {
    if (_isAdmin || !widget.active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      _rfidFocus.unfocus();
      _rfidFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    repo.removeListener(_onChange);
    _adminSub?.cancel();
    _superSub?.cancel();
    // Signed out: back to the default blue (landing / sign-in screens).
    // After this frame — notifying mid-dispose would rebuild a locked tree.
    Future.microtask(() => YosColors.setRole(ThemeRole.admin));
    _requestsSub?.cancel();
    _parkedSub?.cancel();
    _overstayTick?.cancel();
    _rfid.dispose();
    _rfidFocus.dispose();
    super.dispose();
  }

  /// A card tapped on the dashboard routes to the Scan RFID Card screen,
  /// which handles the lookup and receipt there — so every card scan
  /// happens in one place, and the collector is already on the scan
  /// screen for the next car. Admin's job here is oversight/editing, never
  /// the day-to-day scan/log/print work, so this bails out for an admin
  /// session even though the capture field below is already never built
  /// for one — a defensive second guard, not the only one.
  Future<void> _onRfidScanned(String raw) async {
    final tag = raw.trim();
    _rfid.clear();
    if (tag.isEmpty || _isAdmin) return;
    // The hidden capture field can keep Android's text-input connection
    // even while another screen (e.g. Registered Vehicles) is pushed on
    // top, so a scan meant for that screen would otherwise land here.
    // Only act when the dashboard itself is showing.
    if (!widget.active || ModalRoute.of(context)?.isCurrent == false) return;
    await _open(RfidScanScreen(initialTag: tag));
  }

  /// Pushes [screen] and, once it's popped, hands focus back to the hidden
  /// RFID capture field — the pushed screen may have taken focus (e.g.
  /// Registered Vehicles' autofocused search), and nothing else restores
  /// it, so the next card tap here would otherwise go nowhere.
  Future<void> _open(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _reclaimRfidFocus();
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final role = _isSuperAdmin
        ? t('Super Admin', 'Super Admin')
        : _isAdmin
            ? t('Admin', 'Admin')
            : t('Collector', 'Kolektor');
    if (h < 12) return '${t('Good Morning', 'Magandang Umaga')}, $role';
    if (h < 18) return '${t('Good Afternoon', 'Magandang Hapon')}, $role';
    return '${t('Good Evening', 'Magandang Gabi')}, $role';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    // Fixed dark icons, not mode-tracking: the hero below always paints
    // the same pale-blue gradient behind the status bar now, in both
    // modes (see the hero Container's own comment on why), so the status
    // bar no longer needs to flip with the app's light/dark toggle either.
    // Overrides main.dart's app-wide setting only while this screen is on
    // top; Flutter restores it on navigation away.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: YosColors.bg,
        // Light mode's full-bleed backdrop reuses dark mode's own accent
        // pair (the pale end of this palette) instead of continuing the
        // hero's dark navy/royal-blue gradient all the way down — the
        // hero stays a distinct dark moment (it paints its own opaque
        // gradient over this, see below), while everything below it sits
        // on this paler blue instead. Dark mode keeps a genuinely dark
        // canvas for the same reason light mode's backdrop exists —
        // flooding the whole screen with a pale accent would fight the
        // point of dark mode — but it's a short gradient fading from the
        // hero's own bottom tone (accentDark, already part of the default
        // palette, not a new color) down into the flat dark canvas,
        // rather than a flat fill on its own: a flat fill right under a
        // hero that always paints pale (see below) left a hard seam right
        // where the hero's rect ends. The fade (stops cut it off by 30%
        // of the screen) means only the area right below the hero blends
        // — the rest of the canvas stays plain YosColors.bg, same as
        // before.
        body: Container(
          decoration: BoxDecoration(
            gradient: YosColors.isDark
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [YosColors.accentDark, YosColors.bg],
                    stops: const [0.0, 0.3],
                  )
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [YosColors.accentDeepDark, YosColors.accentDark],
                  ),
          ),
          child: TouchGlowOverlay(
            // top: false — the hero block below paints its own gradient
            // behind the status bar (see its padding) instead of stopping
            // at it, so this only insets the sides/bottom for everything
            // else.
            child: SafeArea(
              top: false,
              child: StreamBuilder<List<ParkingTransaction>>(
                stream: _todayTx,
                builder: (context, snap) {
                  final txs = snap.data ?? const <ParkingTransaction>[];
                  final pending = txs.where((t) => t.pendingSync).length;
                  final revenue = txs.fold<double>(0, (s, t) => s + t.totalPaid);
                  const goal = 60;
                  final ringVal = (txs.length / goal).clamp(0.0, 1.0);

                  return ListView(
                    // No uniform inset here anymore: the hero block below
                    // needs to bleed edge-to-edge, so its own padding is
                    // internal, and everything after it is wrapped in its
                    // own Padding instead (see below).
                    padding: EdgeInsets.zero,
                    children: [
                      // ---- Accent hero: greeting/header + today's
                      // collections. Always paints the same pale-blue
                      // gradient now, in both modes — accentDeepDark/
                      // accentDark specifically, not the mode-resolved
                      // accentDeep/accent (light mode's own accent pair is
                      // the dark navy/royal blue used for buttons etc.
                      // elsewhere in the app; the hero deliberately doesn't
                      // track that here, by request, so it stays the pale
                      // shade in both modes instead). Every color inside
                      // this hero below is a fixed dark ink now rather than
                      // the mode-tracking onAccent, for the same reason.
                      // Sits on top of the paler backdrop the Scaffold body
                      // paints behind everything (see that Container's own
                      // comment) — the hero's opaque gradient covers its
                      // own rectangle, and the body's shows through
                      // everywhere below it (now the same shade, so the
                      // seam is intentionally invisible). Extra top padding
                      // (status bar height) instead of a SafeArea here,
                      // since the outer SafeArea is top:false — that's what
                      // lets the gradient itself paint behind the status
                      // bar while the greeting text still clears it.
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.fromLTRB(20,
                            MediaQuery.of(context).padding.top + 10, 20, 18),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              YosColors.accentDeepDark,
                              YosColors.accentDark
                            ],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PopIn(
                              child: LayoutBuilder(
                                builder: (context, c) {
                                  final tiny = c.maxWidth < 340;

                                  final titleBlock = Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: Text(_greeting(),
                                            maxLines: 1,
                                            softWrap: false,
                                            style: TextStyle(
                                                // YosColors.onAccentSoft, not a
                                                // fixed color: the hero's
                                                // gradient (accentDeep/
                                                // accent) sets the contrast
                                                // rule for whatever's on top
                                                // of it — see onAccent's own
                                                // comment.
                                                color: YosColors.onAccentSoft
                                                    .withValues(alpha: 0.72),
                                                fontSize: tiny ? 13 : 15,
                                                fontWeight: FontWeight.w600)),
                                      ),
                                      FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                            _titleCase(repo.currentUserName),
                                            maxLines: 1,
                                            softWrap: false,
                                            style: text.headlineMedium
                                                ?.copyWith(
                                                    fontSize: tiny ? 26 : 30,
                                                    color: YosColors
                                                        .onAccentSoft)),
                                      ),
                                      const SizedBox(height: 6),
                                      SyncBadge(
                                          online: repo.online,
                                          pendingCount: pending),
                                    ],
                                  );

                                  // Printer, Collectors, Change Password,
                                  // and Log out all moved into their own
                                  // bottom-nav tabs/actions (see RootShell)
                                  // — nothing here opens them anymore.
                                  // Header buttons stay reserved for an
                                  // active notification (pending access
                                  // requests) plus the theme toggle; sync
                                  // status now sits under the greeting/role
                                  // text instead of its own row further
                                  // down. The dark/light toggle that used to
                                  // sit here is gone — the app is light-mode
                                  // only now, by request.
                                  final buttons = <Widget>[
                                    // Everyone gets overstay alerts; access
                                    // requests are admin-only (only an admin
                                    // can read access_requests — see
                                    // firestore.rules).
                                    _NotificationButton(
                                      count: (_isAdmin
                                              ? _pendingRequests.length
                                              : 0) +
                                          _overstayCount,
                                      // _open hands the RFID capture field
                                      // its focus back afterwards.
                                      onTap: () => _open(NotificationsScreen(
                                          isAdmin: _isAdmin)),
                                    ),
                                  ];

                                  return Row(
                                    children: [
                                      Expanded(child: titleBlock),
                                      const SizedBox(width: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: buttons,
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Last thing the hero's own gradient covers —
                            // Transactions/Average moved out below (see the
                            // "everything else" section right after this
                            // Container closes), so the pale-hero/plain-
                            // canvas seam now falls right after this instead
                            // of after the stat cards. A plain static
                            // readout now, not the swipeable/auto-scrolling
                            // past-days carousel this used to be — dropped
                            // by request.
                            PopIn(
                              delayMs: 80,
                              child: _TodayCollections(
                                todayRevenue: revenue,
                                todayPending: pending,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ---- Everything else — off the hero's pale gradient
                      // now, sitting directly on the plain canvas below it
                      // (light mode's own pale-blue backdrop, or dark
                      // mode's plain dark one — see the Scaffold body
                      // above); every widget here paints its own opaque
                      // card background on top of that, except the bare
                      // "Quick actions" label below.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Transactions/Average — moved down here from
                            // the hero above so the pale gradient stays
                            // exclusive to the greeting/carousel; these two
                            // keep their own opaque fills (white vs
                            // accentSoft) regardless, so they read the same
                            // as before, just against a different backdrop.
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
                                  // Plain gap, not a vertical rule: now that
                                  // each stat has its own card fill (white
                                  // vs accentSoft), the two colors already
                                  // separate them — a line drawn in the
                                  // space between two rounded cards read as
                                  // a stray mark, not a meaningful divider.
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: PopIn(
                                      delayMs: 200,
                                      child: _AverageCard(
                                        average: txs.isEmpty
                                            ? 0
                                            : revenue / txs.length,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (_isAdmin && _pendingRequests.isNotEmpty) ...[
                              PopIn(
                                delayMs: 220,
                                child: _PendingResetsCard(
                                    requests: _pendingRequests),
                              ),
                              const SizedBox(height: 14),
                            ],
                            // Invisible RFID capture field — no visible "Tap
                            // RFID card" UI, but still autofocused and wired
                            // to _onRfidScanned so a directly-connected
                            // (OTG) reader's keystrokes are caught the same
                            // as at Vehicle Entry. Offstage keeps it out of
                            // layout/paint entirely while leaving
                            // focus/text-input untouched. Not readOnly: that
                            // would drop the platform text-input connection
                            // this needs to actually receive the reader's
                            // keystrokes on Android — keyboardType.none
                            // alone is enough to keep the on-screen keyboard
                            // from popping up. Not built at all for an
                            // admin session — scanning/logging/printing is
                            // Collector work; Admin's dashboard tiles
                            // already leave that whole path off (see
                            // _tiles), so this field shouldn't silently
                            // keep listening for it underneath.
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

                            // A collector's two everyday jobs, as big
                            // buttons up top instead of tiles in the grid.
                            if (!_isAdmin) ...[
                              Row(
                                children: [
                                  Expanded(
                                    child: _BigAction(
                                      icon: Icons.contactless_rounded,
                                      label: t('Scan RFID Card',
                                          'I-scan ang RFID Card'),
                                      filled: true,
                                      onTap: () =>
                                          _open(const RfidScanScreen()),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _BigAction(
                                      icon: Icons.edit_note_rounded,
                                      label: t('Manual Entry',
                                          'Manu-manong Entry'),
                                      onTap: () =>
                                          _open(const VehicleEntryScreen()),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                            ],
                            Padding(
                              padding:
                                  const EdgeInsets.only(left: 4, bottom: 4),
                              // YosColors.ink, not onAccent: this canvas
                              // (dark mode's plain background, or light
                              // mode's pale-blue backdrop below the hero —
                              // see the Scaffold body's own comment) is
                              // light in light mode and dark in dark mode,
                              // same shape ink already tracks — it's only
                              // the hero itself that inverts that, and this
                              // label isn't inside the hero.
                              child: Text(t('Quick Actions', 'Mabilisang Aksyon'),
                                  style: TextStyle(
                                      color: YosColors.ink,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 18)),
                            ),

                            // Fixed at 2 columns regardless of width — was
                            // previously responsive (1/2/3 columns) but that
                            // read as inconsistent rather than adaptive.
                            GridView(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              // A fixed pixel height instead of
                              // childAspectRatio: the tile's content (icon
                              // beside one line of text) has a fixed height
                              // regardless of screen width, so tying height
                              // to width (aspect ratio) made the cards
                              // balloon on wider screens even though the
                              // content inside stayed the same size, leaving
                              // a lot of empty space.
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 10,
                                mainAxisExtent: 76,
                              ),
                              children: _tiles(context)
                                  .asMap()
                                  .entries
                                  .map((e) => PopIn(
                                        delayMs: 240 + e.key * 50,
                                        child: e.value,
                                      ))
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
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
          icon: Icons.receipt_long_rounded,
          title: t('Transaction Logs', 'Mga Log ng Transaksyon'),
          onTap: () => _open(const LogsScreen()),
        ),
        _NavTile(
          glyph: '₱',
          title: t('Fee Matrix', 'Talaan ng Bayarin'),
          onTap: () => _open(const FeesScreen()),
        ),
        _NavTile(
          icon: Icons.security_rounded,
          title: t('Audit Trail', 'Talaan ng Audit'),
          onTap: () => _open(const AuditScreen()),
        ),
        // Everyone: collectors register vehicles; Admins also need it to
        // delete one (deleting is Admin-only).
        _NavTile(
          icon: Icons.directions_car_filled_rounded,
          title: t('Registered Vehicles', 'Mga Nakarehistrong Sasakyan'),
          onTap: () => _open(const RegistryScreen()),
        ),
        _NavTile(
          icon: Icons.loyalty_rounded,
          title: t('RFID Points', 'RFID Points'),
          onTap: () => _open(const RfidPointsScreen()),
        ),
        // Scan RFID Card / Manual Entry are the big buttons above the
        // grid for collectors (see _BigAction).
        _NavTile(
          icon: Icons.menu_book_rounded,
          title: t('Daily Blotter', 'Blotter'),
          onTap: () => _open(BlotterScreen(isAdmin: _isAdmin)),
        ),
        if (_isAdmin)
          _NavTile(
            icon: Icons.bar_chart_rounded,
            title: t('Collection Reports', 'Ulat ng Koleksyon'),
            onTap: () => _open(const ReportsScreen()),
          ),
        if (_isSuperAdmin)
          _NavTile(
            icon: Icons.bug_report_rounded,
            title: t('Error Logs', 'Mga Error Log'),
            onTap: () => _open(const ErrorLogsScreen()),
          ),
      ];
}

/// Today's collections readout behind the hero's headline stat — a
/// manually swipeable week-in-review: today's page (the rightmost, shown
/// first) plus the 7 days before it, swipe right-to-left to look back one
/// day at a time. Manual only, no auto-advance — the auto-scrolling
/// version of this was dropped by request; this is just the "look back at
/// the past week" swipe brought back on top of that static page.
class _TodayCollections extends StatefulWidget {
  const _TodayCollections({
    required this.todayRevenue,
    required this.todayPending,
  });

  final double todayRevenue;
  final int todayPending;

  static const _pastDays = 7;
  static const _pageCount = _pastDays + 1;

  @override
  State<_TodayCollections> createState() => _TodayCollectionsState();
}

class _TodayCollectionsState extends State<_TodayCollections> {
  late final _controller =
      PageController(initialPage: _TodayCollections._pastDays);
  int _page = _TodayCollections._pastDays;

  // One cached future per day index — a day that's already over never
  // changes, so swiping back and forth shouldn't re-hit Firestore every
  // time.
  final Map<int, Future<List<ParkingTransaction>>> _pastCache = {};

  DateTime _dateForPage(int pageIndex) {
    final daysAgo = _TodayCollections._pastDays - pageIndex;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(Duration(days: daysAgo));
  }

  Future<List<ParkingTransaction>> _pastDayTx(int pageIndex) =>
      _pastCache.putIfAbsent(
          pageIndex,
          () => YosRepository.instance
              .transactionsForDate(_dateForPage(pageIndex)));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 84,
          child: PageView.builder(
            controller: _controller,
            itemCount: _TodayCollections._pageCount,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) {
              final isToday = i == _TodayCollections._pastDays;
              if (isToday) {
                // Today's own revenue is already known synchronously (the
                // live stream up in DashboardScreen), but "vs yesterday"
                // still needs yesterday's total fetched.
                return FutureBuilder<List<ParkingTransaction>>(
                  future: _pastDayTx(i - 1),
                  builder: (context, snap) => _CollectionsPage(
                    label: t("Today's Collections", 'Koleksyon Ngayong Araw'),
                    revenue: widget.todayRevenue,
                    pending: widget.todayPending,
                    previousRevenue:
                        snap.data?.fold<double>(0, (s, t) => s + t.totalPaid),
                  ),
                );
              }
              return FutureBuilder<List<List<ParkingTransaction>>>(
                future: Future.wait([
                  _pastDayTx(i),
                  if (i > 0) _pastDayTx(i - 1) else Future.value(const []),
                ]),
                builder: (context, snap) {
                  final results = snap.data;
                  if (results == null) {
                    return Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: YosColors.onAccentSoft),
                      ),
                    );
                  }
                  final txs = results[0];
                  final revenue = txs.fold<double>(0, (s, t) => s + t.totalPaid);
                  final dayStart = _dateForPage(i);
                  final previousRevenue = i > 0
                      ? results[1].fold<double>(0, (s, t) => s + t.totalPaid)
                      : null;
                  return _CollectionsPage(
                    label: DateFormat('MMM d').format(dayStart),
                    revenue: revenue,
                    pending: 0,
                    previousRevenue: previousRevenue,
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_TodayCollections._pageCount, (i) {
            final active = i == _page;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: active ? 16 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: YosColors.onAccentSoft
                    .withValues(alpha: active ? 0.9 : 0.35),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// [_TodayCollections]' content — a label, the day's total, and a
/// percentage-vs-previous-day row (or a fallback when there's nothing to
/// compare against yet). Sits directly on the hero's own gradient, not a
/// separate card, so every color here reads off [YosColors.onAccentSoft]
/// rather than the canvas-relative ink/sub.
class _CollectionsPage extends StatelessWidget {
  const _CollectionsPage({
    required this.label,
    required this.revenue,
    required this.pending,
    required this.previousRevenue,
  });

  final String label;
  final double revenue;
  final int pending;
  final double? previousRevenue;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final money = NumberFormat.currency(symbol: '₱', decimalDigits: 0);
    final previous = previousRevenue;
    final pctChange = (previous == null || previous <= 0)
        ? null
        : (revenue - previous) / previous * 100;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: YosColors.onAccentSoft.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w600,
                      fontSize: 14)),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: OdometerCounter(
                  value: money.format(revenue),
                  style: text.displayLarge
                      ?.copyWith(fontSize: 34, color: YosColors.onAccentSoft),
                ),
              ),
              const SizedBox(height: 6),
              if (pctChange != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      pctChange >= 0
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 14,
                      // Semantic good/bad, not onAccent — an accent-family
                      // color here would be lime-on-lime, barely visible
                      // against the hero's own background.
                      color: pctChange >= 0 ? YosColors.good : YosColors.bad,
                    ),
                    const SizedBox(width: 2),
                    Text('${pctChange.abs().toStringAsFixed(1)}%',
                        style: TextStyle(
                            color:
                                pctChange >= 0 ? YosColors.good : YosColors.bad,
                            fontWeight: FontWeight.w800,
                            fontSize: 12)),
                    const SizedBox(width: 4),
                    Text(t('vs day before', 'kumpara sa nakaraang araw'),
                        style: TextStyle(
                            color:
                                YosColors.onAccentSoft.withValues(alpha: 0.72),
                            fontWeight: FontWeight.w600,
                            fontSize: 12)),
                  ],
                )
              else
                Text(
                    pending > 0
                        ? t('$pending waiting to sync',
                            '$pending naghihintay mai-sync')
                        : t('No data to compare yet',
                            'Wala pang datos na maikukumpara'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: YosColors.onAccentSoft.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                        fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Today's transaction count, with a small goal-progress ring on the side.
/// No card box — sits directly on the scrollable background, the same way
/// the hero's "Today's collections" does, rather than being boxed off from
/// it.
class _TransactionsCard extends StatelessWidget {
  const _TransactionsCard({required this.count, required this.ringValue});

  final int count;
  final double ringValue;

  @override
  Widget build(BuildContext context) {
    // Fixed white, not the mode-tracking YosColors.surface — that resolves
    // to a dark navy in dark mode, which made this card's text (a fixed
    // dark onAccentSoft, correct only on a pale surface) unreadable
    // against its own background. A literal light fill, same reasoning as
    // _AverageCard's fixed accentSoft below: both stay pale in either
    // mode, distinct from each other rather than merging into one long
    // run of numbers.
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: YosColors.surfaceLight,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('Transactions', 'Mga Transaksyon'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: YosColors.onAccentSoft.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
          const SizedBox(height: 10),
          // Stack, not a Row: a Row placed the ring right after the count
          // (wherever that happened to end), not centered in the column.
          // The count stays pinned to the left edge; the ring centers on
          // the full column width regardless of how wide the count is.
          SizedBox(
            width: double.infinity,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: OdometerCounter(
                      value: '$count',
                      style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: YosColors.onAccentSoft),
                    ),
                  ),
                ),
                ProgressRing(
                  value: ringValue,
                  size: 48,
                  stroke: 5,
                  color: YosColors.accentDeep,
                  track: const Color(0x1F16161A),
                  child: Text(t('Today', 'Ngayon'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          color: YosColors.onAccentSoft)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Average fee per transaction today. No trend sparkline anymore — it only
/// ever drew as a flat line against zero-transaction test data and added
/// height without adding information.
class _AverageCard extends StatelessWidget {
  const _AverageCard({required this.average});

  final double average;

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.currency(symbol: '₱', decimalDigits: 0);
    // accentSoft, not _TransactionsCard's white — two different fills so
    // the pair reads as two distinct cards rather than one long block.
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: YosColors.accentSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('Average', 'Karaniwan'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: YosColors.onAccentSoft.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: OdometerCounter(
              value: money.format(average),
              style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: YosColors.onAccentSoft),
            ),
          ),
        ],
      ),
    );
  }
}

/// Big, easy-to-hit button for a collector's main jobs (Scan RFID Card,
/// Manual Entry) — [filled] in the role color for the primary one,
/// outlined for the other.
class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : YosColors.accentDeep;
    return Material(
      color: filled ? YosColors.accent : YosColors.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          height: 96,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: filled
                ? null
                : Border.all(color: YosColors.accent, width: 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 34),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label,
                    maxLines: 1,
                    style: TextStyle(
                        color: fg, fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    this.icon,
    this.glyph,
    required this.title,
    required this.onTap,
  }) : assert(icon != null || glyph != null);
  final IconData? icon;

  /// A text symbol drawn in place of [icon] — e.g. "₱", which Material
  /// Icons doesn't have.
  final String? glyph;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Compact icon-over-label tile, in the design's colors: a white card
    // with a navy icon in a pale blue-gray box — calm and easy to read in
    // sunlight.
    return GlassCard(
      onTap: onTap,
      color: YosColors.surface,
      borderRadius: 20,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                color: YosColors.moss,
                borderRadius: BorderRadius.circular(10)),
            child: glyph != null
                ? Center(
                    child: Text(glyph!,
                        style: TextStyle(
                            color: YosColors.accent,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            height: 1)))
                : Icon(icon, color: YosColors.accent, size: 17),
          ),
          const SizedBox(height: 4),
          // Flexible + FittedBox, not a bare Text: at a bumped-up
          // accessibility text scale or a long two-word title (e.g.
          // "Registered vehicles"), a fixed-size label was tall enough to
          // push this column past the grid cell's aspect-ratio height,
          // which is exactly what threw the "bottom overflowed by N
          // pixels" error — scaling the whole label block down to fit
          // removes that failure mode instead of just guessing a cell
          // height that happens to be tall enough today.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      height: 1.15)),
            ),
          ),
        ],
      ),
    );
  }
}

/// "JUAN DELA CRUZ" / "juan dela cruz" → "Juan Dela Cruz", however the name
/// was typed in when the account was created.
String _titleCase(String s) => formatPersonName(s);

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
                        ? t('1 collector needs a password reset',
                            'May 1 kolektor na kailangan ng password reset')
                        : t(
                            '${requests.length} collectors need a password reset',
                            '${requests.length} kolektor ang kailangan ng password reset'),
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 14)),
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
                        r.name.isEmpty
                            ? t('(no name given)', '(walang pangalan)')
                            : _titleCase(r.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w700,
                            fontSize: 13)),
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
                    child: Text(t('Reset Password', 'I-reset ang Password'),
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Bell icon with a red count badge for pending access requests plus
/// overstaying vehicles — sits at the top-right of the dashboard's accent
/// hero header.
class _NotificationButton extends StatelessWidget {
  const _NotificationButton({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        // Fixed white circle with a fixed dark icon, not mode-branched:
        // the hero this sits on is the same pale-blue gradient in both
        // modes now (see the hero Container's own comment), so there's no
        // longer a "which mode is this" question to answer here — a solid
        // white circle with dark ink guarantees legibility regardless.
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: kSoftShadow,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: Icon(Icons.notifications_rounded,
                  size: 18, color: YosColors.onAccentSoft),
            ),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 18, minHeight: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: YosColors.bad,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(count > 99 ? '99+' : '$count',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
