import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/auth_errors.dart';
import '../core/theme.dart';
import '../models/access_request.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
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
      setState(() => _error =
          t('Couldn\'t send the request: $e', 'Hindi maipadala ang kahilingan: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Signs in to the brand-new account the admin just created (see
  /// resetCollectorPassword) with the passcode the admin told this
  /// collector directly, then goes straight to the dashboard — no Face ID
  /// capture demanded here. The admin's out-of-band identity check (they
  /// recognized who this collector is before granting the reset) stands in
  /// for it, same trust model the rest of this recovery flow already rests
  /// on — see this class's own doc comment.
  ///
  /// Trade-off: this device ends up with no local FaceProfile for the new
  /// account (FaceAuthService.enroll needs a real captured embedding,
  /// which this path never produces), so a *later* Face ID scan on this
  /// device won't recognize them, and PasswordLoginScreen's own local-only
  /// candidate list won't have them either — this same "notify admin" flow
  /// is the way back in either time. A collector who wants Face ID set up
  /// on this device can still do that afterward from Profile.
  Future<void> _signInWithPasscode(String newUsername) async {
    if (_passcode.text.isEmpty) {
      setState(() =>
          _error = t('Enter your new passcode', 'Ilagay ang iyong bagong passcode'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = YosRepository.emailForUsername(newUsername);
      final password = _passcode.text;
      await YosRepository.instance.login(email, password);
      // A real password sign-in, granted by the admin, already stands in
      // for Face ID enrollment here — see this method's own doc comment.
      await YosRepository.instance.markFaceIdEnrolled();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => const RootShell(skipEnrollCheck: true)),
        (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = authErrorMessage(e.code));
    } catch (e) {
      setState(() => _error = t('Couldn\'t sign in: $e', 'Hindi makapag-sign-in: $e'));
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
          Positioned(
            top: -80,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SizedBox(
                height: 340,
                child: DecoratedBox(
                    decoration: BoxDecoration(gradient: kAmbientGlow)),
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
                          child: Text(t('RECOVER ACCESS', 'BAWIIN ANG ACCESS'),
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
                                    text: t('Notify your\n', 'Ipaalam sa\n'),
                                    style: text.displayLarge
                                        ?.copyWith(fontSize: 40)),
                                TextSpan(
                                    text: t('admin', 'admin'),
                                    style: text.displayLarge?.copyWith(
                                        fontSize: 40,
                                        color: YosColors.accentDeep)),
                              ],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                            t(
                                'Can\'t scan Face ID on this device? Let your '
                                'admin know so they can help you get back in.',
                                'Hindi ma-scan ang Face ID sa device na ito? '
                                    'Ipaalam sa iyong admin para matulungan '
                                    'kang makapasok ulit.'),
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
                                          const Icon(Icons.check_circle_rounded,
                                              size: 48, color: YosColors.good),
                                          const SizedBox(height: 14),
                                          Text(
                                              t('Admin notified',
                                                  'Naipaalam na sa Admin'),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                  color: YosColors.ink,
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w800)),
                                          const SizedBox(height: 6),
                                          Text(
                                              t(
                                                  'They\'ll reach out to help '
                                                  'you regain access. Keep this '
                                                  'screen open — it\'ll update '
                                                  'automatically once they do.',
                                                  'Makikipag-ugnayan sila para '
                                                      'tulungan kang mabawi ang '
                                                      'iyong access. Panatilihing '
                                                      'bukas ang screen na ito — '
                                                      'awtomatikong mag-u-update '
                                                      'ito kapag ginawa na nila.'),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                  color: YosColors.sub,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600)),
                                          const SizedBox(height: 20),
                                          BreathingGlowButton(
                                            label: t('Back to sign in',
                                                'Bumalik sa Pag-sign-in'),
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
                                          decoration: InputDecoration(
                                            labelText: t('Your Full Name',
                                                'Buong pangalan mo'),
                                            prefixIcon: const Icon(
                                                Icons.person_outline_rounded),
                                          ),
                                          onFieldSubmitted: (_) => _submit(),
                                          validator: (v) =>
                                              (v == null || v.trim().length < 2)
                                                  ? t('Enter your full name',
                                                      'Ilagay ang iyong buong pangalan')
                                                  : null,
                                        ),
                                        AnimatedSize(
                                          duration:
                                              const Duration(milliseconds: 250),
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
                                                          color: YosColors.bad,
                                                          size: 18),
                                                      const SizedBox(width: 8),
                                                      Expanded(
                                                        child: Text(_error!,
                                                            style: const TextStyle(
                                                                color: YosColors
                                                                    .bad,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                fontSize: 13)),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                        ),
                                        const SizedBox(height: 22),
                                        _busy
                                            ? Center(
                                                child: SizedBox(
                                                  width: 32,
                                                  height: 32,
                                                  child:
                                                      CircularProgressIndicator(
                                                          color: YosColors.ink,
                                                          strokeWidth: 3),
                                                ),
                                              )
                                            : BreathingGlowButton(
                                                label: t('Notify admin',
                                                    'Ipaalam sa Admin'),
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
        Text(t('Your admin reset your access', 'Na-reset ng iyong admin ang iyong access'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: YosColors.ink,
                fontWeight: FontWeight.w800,
                fontSize: 16)),
        const SizedBox(height: 6),
        Text(t('New username: $username', 'Bagong username: $username'),
            textAlign: TextAlign.center,
            style: TextStyle(
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
            labelText: t('New passcode', 'Bagong Passcode'),
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
            ? Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                      color: YosColors.ink, strokeWidth: 3),
                ),
              )
            : BreathingGlowButton(
                label: t('Sign In', 'Mag-sign-in'),
                icon: Icons.login_rounded,
                onPressed: onSubmit,
              ),
      ],
    );
  }
}
