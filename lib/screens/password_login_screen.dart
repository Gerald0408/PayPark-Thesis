import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/auth_errors.dart';
import '../core/theme.dart';
import '../core/username.dart';
import '../services/face_auth_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import 'access_request_screen.dart';
import 'face_enroll_screen.dart';
import 'root_shell.dart';

/// Password sign-in, reached from FaceLoginScreen's "Type password
/// instead" — offered only once a scan has actually failed (new/
/// reinstalled device, bad lighting, camera trouble). Authenticating here
/// is proof of identity, so on a device that already has this account's
/// Face ID locally enrolled, it's enough to go straight to [RootShell]
/// afterward — no re-scan demanded on the spot. On a device that
/// *doesn't* (this account's first time here, or the earlier local
/// enrollment got wiped/reinstalled — see FaceAuthService), this routes
/// through [FaceEnrollScreen] instead of the dashboard, same as
/// registration does: otherwise "Signed in ✓, Face ID still not
/// recognized" would just repeat forever on this device, since nothing
/// else ever captures a face here. That's the actual promise this
/// screen's own copy below already makes.
///
/// Asks for username + password, not password alone: a collector's real
/// account lives in Firebase, not on any one phone, so this authenticates
/// against Firebase directly rather than guessing an identity from
/// whatever face profile happens to be cached locally on THIS device (see
/// FaceAuthService). That's what makes this work correctly on any of a
/// collector's phones — A, B, C, whichever they're holding right now —
/// without ever mis-signing them in as a different collector who simply
/// happened to have enrolled Face ID here first.
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
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscurePassword = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final username = normalizeUsername(_username.text);
      final email = YosRepository.emailForUsername(username);
      final password = _password.text;
      final cred = await YosRepository.instance.login(email, password);
      if (!mounted) return;

      final uid = cred.user!.uid;
      final localProfiles = await FaceAuthService.instance.loadProfiles();
      if (!mounted) return;
      final alreadyEnrolledHere = localProfiles.any((p) => p.uid == uid);
      if (alreadyEnrolledHere) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (_) => const RootShell(skipEnrollCheck: true)),
          (_) => false,
        );
        return;
      }

      // No local profile for this account on this device — Face ID would
      // just keep failing here forever otherwise, so capture one now
      // instead of dropping straight into the dashboard. Same shape as
      // RegisterScreen's own post-signup step.
      final user = cred.user!;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => FaceEnrollScreen(
          uid: uid,
          name: user.displayName?.isNotEmpty == true
              ? user.displayName!
              : 'Collector',
          email: email,
          password: password,
          onFinished: (fctx) {
            Navigator.of(fctx).pushAndRemoveUntil(
              MaterialPageRoute(
                  builder: (_) => const RootShell(skipEnrollCheck: true)),
              (_) => false,
            );
          },
        ),
      ));
    } on FormatException {
      setState(() =>
          _error = t('Enter a valid username.', 'Ilagay ang wastong username.'));
    } on FirebaseAuthException catch (e) {
      setState(() => _error = authErrorMessage(e.code));
    } catch (e) {
      setState(() =>
          _error = t('Couldn\'t sign in: $e', 'Hindi makapag-sign in: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _forgotPasswordButton() => TextButton(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccessRequestScreen())),
        child: Text(t('Forgot password?', 'Nakalimutan ang password?')),
      );

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
                          child: Text(
                              t('PASSWORD SIGN IN', 'MAG-SIGN IN GAMIT ANG PASSWORD'),
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
                                    text: t('Sign in with\n', 'Mag-sign in gamit\n'),
                                    style: text.displayLarge
                                        ?.copyWith(fontSize: 40)),
                                TextSpan(
                                    text: t('Password', 'ang password'),
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
                                'We\'ll set Face ID back up on this device once '
                                'you\'re signed in.',
                                'Ise-set up namin ulit ang Face ID sa device na '
                                'ito kapag naka-sign in ka na.'),
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
                            child: Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TextFormField(
                                    controller: _username,
                                    autofocus: true,
                                    textInputAction: TextInputAction.next,
                                    autofillHints: const [
                                      AutofillHints.username
                                    ],
                                    decoration: InputDecoration(
                                      labelText: t('Username', 'Username'),
                                      prefixIcon: const Icon(
                                          Icons.person_outline_rounded),
                                    ),
                                    validator: (v) =>
                                        (v == null || v.trim().isEmpty)
                                            ? t('Enter your username',
                                                'Ilagay ang iyong username')
                                            : null,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _password,
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    autofillHints: const [
                                      AutofillHints.password
                                    ],
                                    decoration: InputDecoration(
                                      labelText: t('Password', 'Password'),
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
                                    onFieldSubmitted: (_) => _submit(),
                                    validator: (v) =>
                                        (v == null || v.isEmpty)
                                            ? t('Enter your password',
                                                'Ilagay ang iyong password')
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
                                    duration:
                                        const Duration(milliseconds: 250),
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
                                                      style:
                                                          const TextStyle(
                                                              color:
                                                                  YosColors
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
                                          label: t('Sign In', 'Mag-sign in'),
                                          icon: Icons.login_rounded,
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
