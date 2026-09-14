import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import 'face_login_screen.dart';
import 'register_screen.dart';

/// Collector sign-in — Face ID first, full stop. No username/password
/// form here, and no upfront Collector/Admin picker either: the only way
/// in is a face scan against whatever profiles are enrolled on this
/// device (see FaceLoginScreen's generic 1:N path), and the face match
/// alone decides who actually signs in and whether they land with admin
/// access — nothing on this screen needs to know that in advance.
/// Password sign-in still exists as a last resort ("Type password
/// instead") but only appears on FaceLoginScreen itself, once a scan has
/// actually failed, same for every account including the built-in admin.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  void _faceLogin(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const FaceLoginScreen()));
  }

  void _goRegister(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const RegisterScreen()));
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
                  decoration: BoxDecoration(gradient: kAmbientGlow),
                ),
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
                          child: Text(t('SIGN IN', 'MAG-SIGN IN'),
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
                                    text: t('Welcome\n', 'Maligayang\n'),
                                    style: text.displayLarge
                                        ?.copyWith(fontSize: 44)),
                                TextSpan(
                                    text: t('back!', 'pagbabalik!'),
                                    style: text.displayLarge?.copyWith(
                                        fontSize: 44,
                                        color: YosColors.accentDeep)),
                              ],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                            t('Scan your face to sign in.',
                                'I-scan ang iyong mukha para mag-sign in.'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: YosColors.sub,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 32),
                        PopIn(
                          delayMs: 160,
                          child: GlassCard(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Icon(Icons.face_retouching_natural,
                                    size: 56, color: YosColors.accentDeep),
                                const SizedBox(height: 14),
                                Text(
                                    t('Sign in with Face ID',
                                        'Mag-sign in gamit ang Face ID'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: YosColors.ink,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800)),
                                const SizedBox(height: 6),
                                Text(
                                    t(
                                        'We\'ll match your face against your '
                                        'enrolled profile on this device.',
                                        'Ito-tugma namin ang iyong mukha sa '
                                        'iyong naka-enroll na profile sa '
                                        'device na ito.'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: YosColors.sub,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 20),
                                BreathingGlowButton(
                                  label: t('Scan Face ID', 'I-scan ang Face ID'),
                                  onPressed: () => _faceLogin(context),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        TextButton(
                          onPressed: () => _goRegister(context),
                          child: Text(t('New collector? Register',
                              'Bagong kolektor? Magrehistro')),
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
