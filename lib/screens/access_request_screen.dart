import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/auth_errors.dart';
import '../core/theme.dart';
import '../models/access_request.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import 'root_shell.dart';

/// Replaces the old SMS-OTP forgot-password flow — accounts aren't tied to
/// a phone number anymore, so there's no number to send a code to. Instead
/// this just leaves the admin a pending notification (see
/// YosRepository.requestAccessReset) with the name typed here; the admin
/// recognizes who that is out-of-band and resets their access (see
/// showResetCollectorPasswordDialog), which creates a brand-new account
/// under a new username. Deliberately no verification beyond the typed
/// name — see AccessRequest's class doc for the trust model this rests on.
///
/// The collector stays on this one screen through the whole wait: once
/// sent, it watches its own request live (see
/// YosRepository.watchAccessRequest) and, the moment the admin actually
/// grants the reset, swaps the "waiting" message for a passcode field
/// against the new account the admin just named — no bouncing back
/// through Login/Face ID to find where to type it.
class AccessRequestScreen extends StatefulWidget {
  const AccessRequestScreen({super.key});

  @override
  State<AccessRequestScreen> createState() => _AccessRequestScreenState();
}

class _AccessRequestScreenState extends State<AccessRequestScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _passcode = TextEditingController();
  bool _obscurePasscode = true;
  bool _busy = false;
  bool _sent = false;
  String? _error;

  AccessRequest? _liveRequest;
  StreamSubscription<AccessRequest?>? _watchSub;

  @override
  void dispose() {
    _name.dispose();
    _passcode.dispose();
    _watchSub?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id =
          await YosRepository.instance.requestAccessReset(_name.text.trim());
      if (!mounted) return;
      _watchSub = YosRepository.instance.watchAccessRequest(id).listen(
        (r) {
          if (mounted) setState(() => _liveRequest = r);
        },
        // An unhandled stream error would surface as an uncaught
        // exception (a red screen) rather than just leaving this screen
        // showing its "waiting" state, which is the safe fallback here.
        onError: (Object e) =>
            debugPrint('watchAccessRequest stream error (ignored): $e'),
      );
      setState(() => _sent = true);
    } catch (e) {
      setState(() => _error = 'Couldn\'t send the request: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Signs in to the brand-new account the admin just created (see
  /// resetCollectorPassword) with the passcode the admin told this
  /// collector directly, then goes straight to the dashboard — no Face ID
  /// capture here, unlike every other sign-in path in the app. The
  /// admin's out-of-band identity check during the reset stands in for it
  /// on this one path; markFaceIdEnrolled still records the account as
  /// gated-clear (hasFaceId() in firestore.rules would otherwise block
  /// every dashboard read), it just does so without a real biometric
  /// behind it. This account has no Face ID on any device until this
  /// collector separately chooses to enroll one later.
  Future<void> _signInWithPasscode(String newUsername) async {
    if (_passcode.text.isEmpty) {
      setState(() => _error = 'Enter your new passcode');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = YosRepository.emailForUsername(newUsername);
      await YosRepository.instance.login(email, _passcode.text);
      if (!mounted) return;
      await YosRepository.instance.markFaceIdEnrolled();
      try {
        await YosRepository.instance.logAudit(AuditAction.faceEnroll,
            'Signed in via admin-issued passcode — Face ID not captured');
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => const RootShell(skipEnrollCheck: true)),
        (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = authErrorMessage(e.code));
    } catch (e) {
      setState(() => _error = 'Couldn\'t sign in: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(leading: const BackButton()),
      body: Stack(
        children: [
          const Positioned(
            top: -80,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SizedBox(
                height: 340,
                child:
                    DecoratedBox(decoration: BoxDecoration(gradient: kAmbientGlow)),
              ),
            ),
          ),
          TouchGlowOverlay(
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        PopIn(
                          child: Text('RECOVER ACCESS',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: YosColors.accentDeep,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2.4)),
                        ),
                        const SizedBox(height: 10),
                        PopIn(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                    text: 'Notify your\n',
                                    style: text.displayLarge
                                        ?.copyWith(fontSize: 40)),
                                TextSpan(
                                    text: 'admin',
                                    style: text.displayLarge?.copyWith(
                                        fontSize: 40,
                                        color: YosColors.accentDeep)),
                              ],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                            'Can\'t scan Face ID on this device? Let your '
                            'admin know so they can help you get back in.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: YosColors.sub,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 32),
                        PopIn(
                          delayMs: 160,
                          child: GlassCard(
                            padding: const EdgeInsets.all(24),
                            child: _sent
                                ? (_liveRequest?.newUsername != null
                                    ? _PasscodeReady(
                                        username: _liveRequest!.newUsername!,
                                        controller: _passcode,
                                        obscure: _obscurePasscode,
                                        onToggleObscure: () => setState(() =>
                                            _obscurePasscode =
                                                !_obscurePasscode),
                                        error: _error,
                                        busy: _busy,
                                        onSubmit: () => _signInWithPasscode(
                                            _liveRequest!.newUsername!),
                                      )
                                    : Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                              Icons.check_circle_rounded,
                                              size: 48,
                                              color: YosColors.good),
                                          const SizedBox(height: 14),
                                          const Text('Admin notified',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight:
                                                      FontWeight.w800)),
                                          const SizedBox(height: 6),
                                          const Text(
                                              'They\'ll reach out to help '
                                              'you regain access. Keep this '
                                              'screen open — it\'ll update '
                                              'automatically once they do.',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                  color: YosColors.sub,
                                                  fontSize: 13,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                          const SizedBox(height: 20),
                                          BreathingGlowButton(
                                            label: 'Back to sign in',
                                            icon: Icons.arrow_back_rounded,
                                            onPressed: () =>
                                                Navigator.of(context).pop(),
                                          ),
                                        ],
                                      ))
                                : Form(
                                    key: _formKey,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        TextFormField(
                                          controller: _name,
                                          textCapitalization:
                                              TextCapitalization.words,
                                          autofillHints: const [
                                            AutofillHints.name
                                          ],
                                          decoration: const InputDecoration(
                                            labelText: 'Your full name',
                                            prefixIcon: Icon(
                                                Icons.person_outline_rounded),
                                          ),
                                          onFieldSubmitted: (_) => _submit(),
                                          validator: (v) => (v == null ||
                                                  v.trim().length < 2)
                                              ? 'Enter your full name'
                                              : null,
                                        ),
                                        AnimatedSize(
                                          duration: const Duration(
                                              milliseconds: 250),
                                          child: _error == null
                                              ? const SizedBox.shrink()
                                              : Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          top: 14),
                                                  child: Row(
                                                    children: [
                                                      const Icon(
                                                          Icons
                                                              .error_outline_rounded,
                                                          color:
                                                              YosColors.bad,
                                                          size: 18),
                                                      const SizedBox(
                                                          width: 8),
                                                      Expanded(
                                                        child: Text(_error!,
                                                            style: const TextStyle(
                                                                color: YosColors
                                                                    .bad,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                fontSize:
                                                                    13)),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                        ),
                                        const SizedBox(height: 22),
                                        _busy
                                            ? const Center(
                                                child: SizedBox(
                                                  width: 32,
                                                  height: 32,
                                                  child:
                                                      CircularProgressIndicator(
                                                          color:
                                                              YosColors.ink,
                                                          strokeWidth: 3),
                                                ),
                                              )
                                            : BreathingGlowButton(
                                                label: 'Notify admin',
                                                icon: Icons
                                                    .notifications_active_rounded,
                                                onPressed: _submit,
                                              ),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
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

/// Shown in place of the "waiting on admin" message the moment
/// [_AccessRequestScreenState._liveRequest] reports a [newUsername] —
/// the admin has granted the reset and told this collector their new
/// passcode directly (out-of-band, never through this app), so all
/// that's left is typing it in against the account the admin just named.
class _PasscodeReady extends StatelessWidget {
  const _PasscodeReady({
    required this.username,
    required this.controller,
    required this.obscure,
    required this.onToggleObscure,
    required this.error,
    required this.busy,
    required this.onSubmit,
  });

  final String username;
  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final String? error;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.lock_open_rounded, size: 40, color: YosColors.good),
        const SizedBox(height: 12),
        const Text('Your admin reset your access',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 6),
        Text('New username: $username',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: YosColors.sub,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 20),
        TextField(
          controller: controller,
          obscureText: obscure,
          autofocus: true,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => onSubmit(),
          decoration: InputDecoration(
            labelText: 'New passcode',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              icon: Icon(obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              onPressed: onToggleObscure,
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: YosColors.bad, fontSize: 13)),
        ],
        const SizedBox(height: 20),
        busy
            ? const Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                      color: YosColors.ink, strokeWidth: 3),
                ),
              )
            : BreathingGlowButton(
                label: 'Sign in',
                icon: Icons.login_rounded,
                onPressed: onSubmit,
              ),
      ],
    );
  }
}
