import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/collector.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/app_dialog.dart';
import 'dashboard_screen.dart';
import 'face_enroll_screen.dart';
import 'intro_screen.dart';
import 'login_screen.dart';
import 'printer_settings_screen.dart';
import 'profile_screen.dart';

/// Entry point after sign-in — and the single choke point that enforces
/// Face ID as a **mandatory** gate to the dashboard. No signed-in account
/// reaches [DashboardScreen] through here without `face_id_enrolled ==
/// true` on its collectors/{uid} doc (see YosRepository.markFaceIdEnrolled
/// / isCurrentUserFaceIdEnrolled, and hasFaceId() in firestore.rules,
/// which enforces the same thing server-side on every dashboard resource
/// regardless of what this widget does).
///
/// This runs on *every* path into the dashboard, including a resumed
/// session on cold start (main.dart's authStateChanges StreamBuilder sends
/// an already-signed-in user straight here with no login/register screen
/// in between) — which is exactly the path that would otherwise have no
/// opportunity to redirect an unenrolled account. Login/Register screens
/// still take the faster route of going straight to [FaceEnrollScreen]
/// themselves when they already know enrollment is missing (they have the
/// collector's just-typed password in hand); this widget is the fallback
/// for every other case, which is why it has to ask for the password
/// again via [_PasswordGate] — nothing here can read a password back out
/// of Firebase Auth.
class RootShell extends StatefulWidget {
  const RootShell({super.key, this.skipEnrollCheck = false});

  /// True only right after FaceLoginScreen's own scan just matched a
  /// locally-enrolled profile and signed in with it — that already *is*
  /// proof of enrollment (there's no local profile to match without
  /// having enrolled), so re-deriving the same fact here via a fresh
  /// Firestore read is both redundant and, worse, racy: that read lands
  /// moments after login() mints a brand-new auth token, which can
  /// transiently look unrecognized server-side and wrongly bounce an
  /// already-enrolled collector into this screen's password gate right
  /// after they just signed in with their face. Skipping the read here
  /// avoids that race outright instead of just retrying through it.
  final bool skipEnrollCheck;

  @override
  State<RootShell> createState() => _RootShellState();
}

enum _Gate { checking, needsPassword, needsEnroll, granted }

class _RootShellState extends State<RootShell> {
  _Gate _gate = _Gate.checking;
  String? _confirmedPassword;
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    if (widget.skipEnrollCheck) {
      _gate = _Gate.granted;
    } else {
      _check();
    }
  }

  Future<void> _check() async {
    final enrolled = await YosRepository.instance.isCurrentUserFaceIdEnrolled();
    if (!mounted) return;
    setState(() => _gate = enrolled ? _Gate.granted : _Gate.needsPassword);
  }

  Future<void> _confirmPassword(String password) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) return;
    setState(() => _passwordError = null);
    try {
      await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: user.email!, password: password));
      if (!mounted) return;
      setState(() {
        _confirmedPassword = password;
        _gate = _Gate.needsEnroll;
      });
    } on FirebaseAuthException {
      if (mounted) setState(() => _passwordError = 'Incorrect password.');
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_gate) {
      case _Gate.checking:
        return Scaffold(
          backgroundColor: YosColors.bg,
          body:
              Center(child: CircularProgressIndicator(color: YosColors.accent)),
        );
      case _Gate.needsPassword:
        return _PasswordGate(error: _passwordError, onSubmit: _confirmPassword);
      case _Gate.needsEnroll:
        final user = FirebaseAuth.instance.currentUser!;
        return FaceEnrollScreen(
          uid: user.uid,
          name: user.displayName?.isNotEmpty == true
              ? user.displayName!
              : 'Collector',
          email: user.email!,
          password: _confirmedPassword!,
          // Clears the session the password re-confirm above just
          // re-established, so reaching the dashboard afterward requires
          // an actual sign-in rather than riding on that leftover
          // session. Lands on the sign-in screen, not straight into the
          // dashboard — enrolling just proves a face was captured and
          // saved, not that it can be recognized again.
          onFinished: (ctx) async {
            await YosRepository.instance.logout();
            if (!ctx.mounted) return;
            Navigator.of(ctx).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (_) => false,
            );
          },
        );
      case _Gate.granted:
        return const _RootTabs();
    }
  }
}

/// Bottom-navigation shell once RootShell's gate is satisfied — Home,
/// Profile, and Printer are real tabs (an [IndexedStack], not a plain
/// conditional, keeps each one's state — scroll position, StreamBuilder
/// subscriptions — alive across switches instead of rebuilding from
/// scratch every time); Logout is deliberately not a tab with its own
/// screen, since there's nothing to show there — tapping it runs
/// [_confirmLogout] directly and leaves whichever real tab was already
/// showing selected underneath.
class _RootTabs extends StatefulWidget {
  const _RootTabs();

  @override
  State<_RootTabs> createState() => _RootTabsState();
}

class _RootTabsState extends State<_RootTabs> {
  static const _home = 0;
  static const _printer = 2;
  static const _logout = 3;

  int _index = _home;

  /// Admins don't print tickets, so their nav bar leaves the Printer tab
  /// out entirely.
  bool _isAdmin = false;

  StreamSubscription<Collector?>? _profileSub;

  /// True once a real (non-null) profile has actually come through —
  /// guards against treating the stream's very first emission as a
  /// removal if it happens to land before the doc's cached copy is ready.
  bool _sawProfile = false;

  @override
  void initState() {
    super.initState();
    // Watches this account's own collectors/{uid} doc live, so an admin
    // deleting it from another device *while this session is already
    // open* is caught immediately — without this, the dashboard would
    // just keep showing stale local data until some unrelated action
    // happened to hit a Firestore permission-denied.
    _profileSub = YosRepository.instance.currentCollectorProfile.listen(
      (c) {
        if (c != null) {
          _sawProfile = true;
          if (c.isAdmin != _isAdmin && mounted) {
            setState(() {
              _isAdmin = c.isAdmin;
              if (_isAdmin && _index == _printer) _index = _home;
            });
          }
        } else if (_sawProfile) {
          _handleAccountRemoved();
        }
      },
      // This subscribes the moment RootShell mounts — including right
      // after a brand-new sign-in, when the underlying read can
      // transiently hit a permission-denied before Firestore recognizes
      // the just-minted auth token (same well-known race
      // markFaceIdEnrolled/collectorExists already retry for). A stream
      // *error* is never the same thing as "the doc doesn't exist" — an
      // unhandled one here would otherwise surface as an uncaught
      // exception (a red screen) rather than the harmless, self-
      // recovering blip it actually is.
      onError: (Object e) =>
          debugPrint('currentCollectorProfile stream error (ignored): $e'),
    );
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    super.dispose();
  }

  Future<void> _handleAccountRemoved() async {
    if (!mounted) return;
    await showAppConfirmDialog(
      context,
      barrierDismissible: false,
      title: 'Access removed',
      message: 'An admin removed this account. You\'ll need to sign in '
          'again.',
      confirmLabel: 'OK',
    );
    await YosRepository.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const IntroScreen()), (_) => false);
  }

  Future<void> _onTap(int i) async {
    if (i == _logout) {
      await _confirmLogout();
      return;
    }
    setState(() => _index = i);
  }

  Future<void> _confirmLogout() async {
    // A small plain Yes / No.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        title: Text(t('Log Out?', 'Mag-log Out?'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: Text(t('Do you want to log out?', 'Gusto mo bang mag-log out?'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14)),
        // Extra-large Yes / No — the decision is the whole point of
        // this dialog, so the buttons are big, easy targets.
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(60)),
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(t('No', 'Hindi'),
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w500)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: YosColors.bad,
                      minimumSize: const Size.fromHeight(60)),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(t('Yes', 'Oo'),
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w500)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await YosRepository.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const IntroScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YosColors.bg,
      // Lets whichever tab's own body paint behind the floating nav bar
      // instead of stopping at its reserved strip — without this, that
      // strip (and the margin around the floating pill within it) shows
      // this Scaffold's own backgroundColor instead of the active tab's,
      // which read as a stray off-white band under Dashboard's lime
      // background specifically. Profile/Printer are unaffected: their
      // own canvas is already this same backgroundColor, so there's
      // nothing to mismatch.
      extendBody: true,
      // Each tab wrapped in its own RepaintBoundary, and TickerMode-gated
      // so only the visible one keeps animating. Without these, Flutter
      // composites every IndexedStack child into the same paint layer
      // *and* every tab's animations (a tab's entrance PopIns, the
      // tap-glow blob in TouchGlowOverlay) keep right on ticking even
      // while offstage — neither pauses just because its tab isn't the
      // one showing — so a still-running animation from the tab you just
      // left can leave stale pixels bleeding into the freshly-selected
      // tab's frame on switch. Isolating each tab's compositing layer and
      // freezing its tickers when hidden is what stops that "ghost of the
      // previous tab" artifact.
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < 4; i++)
            TickerMode(
              enabled: i == _index,
              child: RepaintBoundary(
                // Deliberately NOT const: a const instance is
                // canonicalized, so the exact same object comes back from
                // this switch on every rebuild of this widget. Flutter's
                // Element.updateChild shortcuts on
                // `identical(oldWidget, newWidget)` and skips calling
                // update()/rebuild() on that child entirely when it sees
                // the same const instance again — a plain (non-const)
                // instance is a new object each time instead, so the
                // normal update path always runs.
                child: switch (i) {
                  0 => DashboardScreen(active: _index == 0),
                  1 => ProfileScreen(),
                  2 => PrinterSettingsScreen(embedded: true),
                  _ => const SizedBox.shrink(), // Logout has no screen.
                },
              ),
            ),
        ],
      ),
      bottomNavigationBar: _FloatingNavBar(
        index: _index,
        onTap: _onTap,
        showPrinter: !_isAdmin,
      ),
    );
  }
}

/// Floating pill-shaped nav bar — a rounded bar inset from the screen
/// edges, where every item sits in its own icon circle and the selected
/// one expands into a circle+label pill lit up in the accent green. Stock
/// Material [BottomNavigationBar] can't do the per-item expand-on-select
/// shape, so this is a small custom widget instead.
class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.index,
    required this.onTap,
    required this.showPrinter,
  });

  /// Tab id of the selected item — its position in [_items], which stays
  /// fixed even when [showPrinter] drops the Printer item from view.
  final int index;
  final ValueChanged<int> onTap;
  final bool showPrinter;

  static const _printerId = 2;

  static const _items = [
    (icon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.person_rounded, label: 'Profile'),
    (icon: Icons.print_rounded, label: 'Printer'),
    (icon: Icons.logout_rounded, label: 'Logout'),
  ];

  /// [_items]' labels stay plain English literals (a const list can't
  /// call [t] itself) — this is the Filipino equivalent for whichever one
  /// is showing.
  static String _label(String en) {
    switch (en) {
      case 'Home':
        return t('Home', 'Home');
      case 'Profile':
        return t('Profile', 'Profile');
      case 'Printer':
        return t('Printer', 'Printer');
      case 'Logout':
        return t('Log Out', 'Mag-log Out');
      default:
        return en;
    }
  }

  // Tracks the app's light/dark mode instead of always being a dark
  // floating surface. Dark mode keeps its original near-black-to-green
  // tones (dark mode's canvas is genuinely dark, not lime — see
  // DashboardScreen's build() for why). Light mode's bar is lime itself
  // now, matching the rest of the screen's lime backdrop, with the
  // selected item picked out by a dark-green (accentDeep) pill — the same
  // fill the dashboard's Quick Actions tiles and hero buttons use — rather
  // than a same-colored fill that would blend straight into the bar, or a
  // plain white one that read as disconnected from the lime around it.
  static Color get _barColor =>
      YosColors.isDark ? const Color(0xFF0C0E11) : YosColors.accent; // gold for the Super Admin
  static Color get _pillColor =>
      YosColors.isDark ? const Color(0xFF1B1F24) : YosColors.accentDeep;
  static Color get _idleCircleColor => YosColors.isDark
      ? const Color(0xFF23272E)
      : YosColors.accentDeep.withValues(alpha: 0.25);
  static Color get _idleIconColor => YosColors.isDark
      ? const Color(0xFF9AA1AE)
      : YosColors.onAccent.withValues(alpha: 0.6);

  @override
  Widget build(BuildContext context) {
    final ids = [
      for (var i = 0; i < _items.length; i++)
        if (showPrinter || i != _printerId) i,
    ];
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: _barColor,
          borderRadius: BorderRadius.circular(999),
          boxShadow: kSoftShadow,
        ),
        child: Row(
          // Leftover row width (after every item claims just its own
          // natural size below) spreads out as gaps *between* items
          // instead of being dumped into the selected pill's background —
          // that dumping is what was leaving a big empty-looking stretch
          // to the right of the selected label.
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Every item is uniformly wrapped in Flexible (never bare, and
            // never Expanded — a *different* concrete type) so the widget
            // at each Row slot has the same runtimeType before and after a
            // tap, letting Flutter update each item's existing element in
            // place instead of tearing down and remounting the whole row
            // on every switch (which is what was producing a one-frame
            // rendering artifact on tab switch). flex: 0 on every item —
            // selected included — means RenderFlex treats all of them as
            // fully inflexible, sized to their own natural content width
            // rather than one of them being stretched to fill the row.
            for (final i in ids) ...[
              if (i != ids.first) const SizedBox(width: 6),
              Flexible(
                flex: 0,
                fit: FlexFit.loose,
                child: _NavPillItem(
                  icon: _items[i].icon,
                  label: _label(_items[i].label),
                  selected: i == index,
                  pillColor: _pillColor,
                  idleCircleColor: _idleCircleColor,
                  idleIconColor: _idleIconColor,
                  onTap: () => onTap(i),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NavPillItem extends StatelessWidget {
  const _NavPillItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.pillColor,
    required this.idleCircleColor,
    required this.idleIconColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color pillColor;
  final Color idleCircleColor;
  final Color idleIconColor;
  final VoidCallback onTap;

  static const _circleSize = 40.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: EdgeInsets.fromLTRB(3, 3, selected ? 14 : 3, 3),
        decoration: BoxDecoration(
          color: selected ? pillColor : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _circleSize,
              height: _circleSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // White in light mode, not accent-colored — the selected
                // pill wrapping this circle is a dark accent color there,
                // so a white badge reads as a clean chip instead of a
                // same-hue blend. Dark mode keeps the accent-colored
                // circle: its pill is near-black, where the (pale, in
                // dark mode) accent already pops.
                color: selected
                    ? (YosColors.isDark ? YosColors.accent : Colors.white)
                    : idleCircleColor,
                shape: BoxShape.circle,
              ),
              // Fixed dark icon when selected, not YosColors.onAccent —
              // see dashboard_screen.dart's _NavTile for why: this
              // circle's fill (white in light mode, pale accent in dark
              // mode) always needs dark ink on top regardless of mode,
              // but onAccent itself now flips to white in light mode.
              child: Icon(icon,
                  color: selected ? const Color(0xFF1B1B1B) : idleIconColor,
                  size: 20),
            ),
            if (selected) ...[
              const SizedBox(width: 10),
              // Fixed white, not YosColors.ink: the selected pill is dark
              // in both modes now (accentDeepLight in light mode, the
              // near-black #1B1F24 in dark mode), so this no longer needs
              // to flip with the toggle.
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-screen "confirm your password to continue" step — the price of
/// [RootShell] not having a plaintext password on hand (see the class doc
/// above). Always offers a way out (sign out) rather than trapping the
/// collector if they don't want to or can't complete this right now.
class _PasswordGate extends StatefulWidget {
  const _PasswordGate({required this.error, required this.onSubmit});
  final String? error;
  final Future<void> Function(String password) onSubmit;

  @override
  State<_PasswordGate> createState() => _PasswordGateState();
}

class _PasswordGateState extends State<_PasswordGate> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty || _busy) return;
    setState(() => _busy = true);
    await widget.onSubmit(_password.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signOut() async {
    await YosRepository.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const IntroScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YosColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.shield_rounded, color: YosColors.accentDeep, size: 48),
              const SizedBox(height: 16),
              const Text('Face ID setup required',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                  'Every collector account needs Face ID enrolled on this '
                  'device before continuing. Confirm your password to set '
                  'it up now.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: YosColors.sub, fontSize: 14)),
              const SizedBox(height: 24),
              TextField(
                controller: _password,
                obscureText: _obscure,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (widget.error != null) ...[
                const SizedBox(height: 8),
                Text(widget.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: YosColors.bad, fontSize: 13)),
              ],
              const SizedBox(height: 20),
              _busy
                  ? Center(
                      child: CircularProgressIndicator(color: YosColors.accent))
                  : FilledButton(
                      onPressed: _submit, child: const Text('Continue')),
              const SizedBox(height: 12),
              TextButton(
                  onPressed: _signOut, child: const Text('Sign out instead')),
            ],
          ),
        ),
      ),
    );
  }
}
