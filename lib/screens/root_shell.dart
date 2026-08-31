import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/collector.dart';
import '../services/firestore_service.dart';
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
        return const Scaffold(
          backgroundColor: YosColors.bg,
          body: Center(
              child: CircularProgressIndicator(color: YosColors.accent)),
        );
      case _Gate.needsPassword:
        return _PasswordGate(
            error: _passwordError, onSubmit: _confirmPassword);
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
  static const _logout = 3;

  int _index = _home;

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
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Access removed'),
        content: const Text(
            'An admin removed this account. You\'ll need to sign in again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
            'You\'ll need to sign in again to start your next collection.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out',
                style: TextStyle(color: YosColors.bad)),
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
      body: IndexedStack(
        index: _index,
        children: const [
          DashboardScreen(),
          ProfileScreen(),
          PrinterSettingsScreen(embedded: true),
          SizedBox.shrink(), // Logout has no screen — see class doc.
        ],
      ),
      bottomNavigationBar: _FloatingNavBar(
        index: _index,
        onTap: _onTap,
      ),
    );
  }
}

/// Floating pill-shaped nav bar — a dark rounded bar inset from the
/// screen edges, where the selected item expands into an icon+label pill
/// and the others sit as bare icons. Stock Material [BottomNavigationBar]
/// can't do the per-item expand-on-select shape, so this is a small
/// custom widget instead.
class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (icon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.person_rounded, label: 'Profile'),
    (icon: Icons.print_rounded, label: 'Printer'),
    (icon: Icons.logout_rounded, label: 'Logout'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: YosColors.accentDeep,
          borderRadius: BorderRadius.circular(999),
          boxShadow: kSoftShadow,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Flexible, not a bare pill: spaceBetween only distributes
            // *extra* space — on a narrow phone or a bumped-up text
            // scale, four pills' combined natural width can exceed what's
            // available, and without something able to shrink, that
            // overflows off the right edge instead of just tightening up.
            for (var i = 0; i < _items.length; i++)
              Flexible(
                child: _NavPillItem(
                  icon: _items[i].icon,
                  label: _items[i].label,
                  selected: i == index,
                  onTap: () => onTap(i),
                ),
              ),
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
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
            horizontal: selected ? 18 : 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white24 : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            if (selected) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
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
              const Icon(Icons.shield_rounded,
                  color: YosColors.accentDeep, size: 48),
              const SizedBox(height: 16),
              const Text('Face ID setup required',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
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
                  ? const Center(
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
