import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/auth_errors.dart';
import '../core/theme.dart';
import '../services/face_auth_service.dart';
import '../services/firestore_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import 'access_request_screen.dart';
import 'face_enroll_screen.dart';
import 'login_screen.dart';

/// Password sign-in, reached from FaceLoginScreen's "Type password
/// instead" — offered only once a scan has actually failed (new/
/// reinstalled device, bad lighting, camera trouble). Authenticating here
/// is proof of identity regardless of whether Face ID has ever matched on
/// this specific device, so this continues into [FaceEnrollScreen] to
/// (re-)capture a local profile afterward — mirrors what the access-
/// recovery flow already does.
///
/// Password-only, no username typed here: this device's own locally
/// enrolled face profiles (see FaceAuthService) already say which
/// account(s) this might be. One profile is the normal case (one
/// collector, one phone) and just checks the typed password against it.
/// More than one (a shared device, or leftover test accounts) still
/// shows the same single password field — see [_submit], which tries the
/// typed password against every locally enrolled email in turn, since
/// only one can ever actually match. Only a phone with *zero* enrolled
/// profiles has no candidate to try at all, so that state alone skips
/// straight to "Forgot password?" instead.
///
/// "Forgot password?" goes to the same [AccessRequestScreen] as
/// FaceLoginScreen's "Recover access" — there's no self-service reset
/// (no phone/OTP anymore), so a forgotten password is just another reason
/// to notify the admin.
class PasswordLoginScreen extends StatefulWidget {
  const PasswordLoginScreen({super.key});

  @override
  State<PasswordLoginScreen> createState() => _PasswordLoginScreenState();
}

class _PasswordLoginScreenState extends State<PasswordLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _obscurePassword = true;
  bool _busy = false;
  String? _error;

  late final Future<List<FaceProfile>> _localProfiles =
      FaceAuthService.instance.loadProfiles();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// Tries the typed password against every locally enrolled [profiles]
  /// candidate in turn — with one enrolled account (the common case)
  /// there's only one attempt; with more than one, each wrong-password
  /// attempt just moves on to the next, since only one can ever actually
  /// match. Only the *last* candidate's failure is what gets shown —
  /// earlier ones failing is expected, not a real error, when there's
  /// more than one account to try.
  Future<void> _submit(List<FaceProfile> profiles) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      FaceProfile? matched;
      FirebaseAuthException? lastFailure;
      for (final profile in profiles) {
        try {
          await YosRepository.instance.login(profile.email, _password.text);
          matched = profile;
          break;
        } on FirebaseAuthException catch (e) {
          lastFailure = e;
        }
      }
      if (matched == null) {
        setState(() => _error = lastFailure != null
            ? authErrorMessage(lastFailure.code)
            : 'Incorrect password.');
        return;
      }
      if (!mounted) return;
      final user = FirebaseAuth.instance.currentUser!;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => FaceEnrollScreen(
            uid: user.uid,
            name: user.displayName?.isNotEmpty == true
                ? user.displayName!
                : 'Collector',
            email: matched!.email,
            password: _password.text,
            // Clears the session this password sign-in just established,
            // so reaching the dashboard afterward requires an actual
            // sign-in rather than riding on that leftover session. Lands
            // on the sign-in screen, not straight into the dashboard —
            // enrolling just proves a face was captured and saved, not
            // that it can be recognized again.
            onFinished: (ctx) async {
              await YosRepository.instance.logout();
              if (!ctx.mounted) return;
              Navigator.of(ctx).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (_) => false,
              );
            },
          ),
        ),
        (_) => false,
      );
    } catch (e) {
      setState(() => _error = 'Couldn\'t sign in: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _forgotPasswordButton() => TextButton(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccessRequestScreen())),
        child: const Text('Forgot password?'),
      );

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
                          child: Text('PASSWORD SIGN IN',
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
                                    text: 'Sign in with\n',
                                    style: text.displayLarge
                                        ?.copyWith(fontSize: 40)),
                                TextSpan(
                                    text: 'password',
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
                            'We\'ll set Face ID back up on this device once '
                            'you\'re signed in.',
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
                            child: FutureBuilder<List<FaceProfile>>(
                              future: _localProfiles,
                              builder: (context, snap) {
                                if (!snap.hasData) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Center(
                                        child: CircularProgressIndicator(
                                            color: YosColors.ink)),
                                  );
                                }
                                final profiles = snap.data!;
                                // Truly nothing to try a password against —
                                // no email candidate exists at all on this
                                // device. Recovery through the admin is the
                                // only path forward here.
                                if (profiles.isEmpty) {
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.help_outline_rounded,
                                          size: 40, color: YosColors.sub),
                                      const SizedBox(height: 12),
                                      const Text(
                                          'No account is set up on this device yet.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14)),
                                      const SizedBox(height: 4),
                                      const Text(
                                          'Let your admin know so they can help.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: YosColors.sub,
                                              fontSize: 13)),
                                      const SizedBox(height: 14),
                                      _forgotPasswordButton(),
                                    ],
                                  );
                                }

                                return Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      // Naming the one account this almost
                                      // certainly is — with more than one
                                      // enrolled here, there's no single
                                      // name to show honestly, so this line
                                      // is skipped rather than guessing.
                                      if (profiles.length == 1) ...[
                                        Text(
                                            'Signing in as ${profiles.first.name}',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 14)),
                                        const SizedBox(height: 16),
                                      ],
                                      TextFormField(
                                        controller: _password,
                                        obscureText: _obscurePassword,
                                        autofocus: true,
                                        autofillHints: const [
                                          AutofillHints.password
                                        ],
                                        decoration: InputDecoration(
                                          labelText: 'Password',
                                          prefixIcon: const Icon(
                                              Icons.lock_outline_rounded),
                                          suffixIcon: IconButton(
                                            icon: Icon(_obscurePassword
                                                ? Icons.visibility_outlined
                                                : Icons
                                                    .visibility_off_outlined),
                                            onPressed: () => setState(() =>
                                                _obscurePassword =
                                                    !_obscurePassword),
                                          ),
                                        ),
                                        onFieldSubmitted: (_) =>
                                            _submit(profiles),
                                        validator: (v) =>
                                            (v == null || v.isEmpty)
                                                ? 'Enter your password'
                                                : null,
                                      ),
                                      // Only offered once a sign-in attempt
                                      // has actually failed — never up
                                      // front, same rule FaceLoginScreen's
                                      // own "Type password instead"
                                      // fallback follows.
                                      if (_error != null)
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: _forgotPasswordButton(),
                                        ),
                                      AnimatedSize(
                                        duration: const Duration(
                                            milliseconds: 250),
                                        child: _error == null
                                            ? const SizedBox.shrink()
                                            : Padding(
                                                padding: const EdgeInsets.only(
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
                                          ? const Center(
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
                                              label: 'Sign in',
                                              icon: Icons.login_rounded,
                                              onPressed: () =>
                                                  _submit(profiles),
                                            ),
                                    ],
                                  ),
                                );
                              },
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
