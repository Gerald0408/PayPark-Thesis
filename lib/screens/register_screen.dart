import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/auth_errors.dart';
import '../core/theme.dart';
import '../core/username.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/toast.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import 'face_enroll_screen.dart';
import 'login_screen.dart';

/// Pascal-cases a typed name so it's stored consistently (e.g. "juan DELA
/// cruz" -> "Juan Dela Cruz") regardless of how the collector actually
/// typed it — the keyboard's own [TextCapitalization.words] only hints at
/// capitalization while typing, it doesn't correct a pasted or
/// autocorrect-mangled value.
String _pascalCaseName(String raw) => raw
    .trim()
    .split(RegExp(r'\s+'))
    .map((w) => w.isEmpty
        ? w
        : w[0].toUpperCase() + w.substring(1).toLowerCase())
    .join(' ');

/// Self-service collector sign-up: full name, a chosen username, phone
/// number, birthday, and a password the collector actually picks and
/// knows.
///
/// This used to auto-generate a random, never-shown password instead —
/// fine while Face ID only ever needed to work on the one device it was
/// captured on, but it silently broke two things once a collector's face
/// might need recognizing on a *different* phone (see FaceLoginScreen's
/// cloud fallback / YosRepository.syncFaceEmbedding): there was no way
/// for them to ever complete that flow's one-time password confirmation,
/// and PasswordLoginScreen's "Type password instead" fallback was
/// already just as unusable for the exact same reason. A real,
/// collector-known password fixes both.
///
/// Always registers as a plain Collector — Admin is a single, pre-seeded
/// built-in account, not something self-registration can grant. See
/// YosRepository.completeRegistration.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  final _birthdayText = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();

  DateTime? _birthday;
  bool _busy = false;
  String? _error;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _phone.dispose();
    _birthdayText.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _pickBirthday() async {
    var temp = _birthday ?? DateTime(DateTime.now().year - 25, 1, 1);
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: YosColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(t('Cancel', 'Kanselahin')),
                  ),
                  Text(t('Birthday', 'Kaarawan'),
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(temp),
                    child: Text(t('Done', 'Tapos')),
                  ),
                ],
              ),
              SizedBox(
                height: 216,
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: temp,
                  minimumYear: 1930,
                  maximumDate: DateTime.now(),
                  onDateTimeChanged: (d) => temp = d,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _birthday = picked;
      _birthdayText.text = DateFormat('MM/dd/yyyy').format(picked);
    });
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = _pascalCaseName(_name.text);
      final username = normalizeUsername(_username.text);
      final phone = _phone.text.trim();
      final birthday = _birthday!;
      final password = _password.text;
      final result = await YosRepository.instance.register(
        name: name,
        username: username,
        password: password,
        phone: phone,
        birthday: birthday,
        wantsAdmin: false,
      );
      if (!mounted) return;
      Toast.success(context, t('Account created', 'Nagawa ang account'));
      final email = YosRepository.emailForUsername(username);
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => FaceEnrollScreen(
          uid: result.cred.user!.uid,
          name: name,
          email: email,
          password: password,
          onFinished: (fctx) async {
            // Clears the session Firebase Auth still holds from account
            // creation, so reaching the dashboard afterward requires an
            // actual sign-in rather than riding on a session left over
            // from registration. Lands on the sign-in screen, not
            // straight into the dashboard — enrolling just proves a face
            // was captured and saved, not that it can be recognized
            // again.
            await YosRepository.instance.logout();
            if (!fctx.mounted) return;
            Navigator.of(fctx).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (_) => false,
            );
          },
        ),
      ));
    } on FormatException {
      setState(() => _error = t(
          'Username must be 3-20 characters: letters, numbers, "." or "_" only.',
          'Ang username ay dapat 3-20 na karakter: mga letra, numero, "." o '
          '"_" lang.'));
    } on FirebaseAuthException catch (e) {
      setState(() => _error = authErrorMessage(e.code));
    } catch (e) {
      setState(() => _error =
          t('Couldn\'t create the account: $e', 'Hindi nagawa ang account: $e'));
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
                          child: Text(t('NEW COLLECTOR', 'BAGONG KOLEKTOR'),
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
                                    text: t('Create your\n', 'Gumawa ng iyong\n'),
                                    style: text.displayLarge
                                        ?.copyWith(fontSize: 40)),
                                TextSpan(
                                    text: t('account', 'account'),
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
                                'Fill in your details. Face ID signs you in '
                                'day-to-day — this password is your backup, '
                                'e.g. if you ever need to sign in on a new '
                                'phone.',
                                'Punan ang iyong mga detalye. Ang Face ID ang '
                                'gagamitin mong mag-sign in araw-araw — ang '
                                'password na ito ay backup mo lang, hal. kung '
                                'kailangan mong mag-sign in sa bagong '
                                'telepono.'),
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
                            child: Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TextFormField(
                                    controller: _name,
                                    textCapitalization:
                                        TextCapitalization.words,
                                    autofillHints: const [AutofillHints.name],
                                    decoration: InputDecoration(
                                      labelText: t('Full name', 'Buong Pangalan'),
                                      prefixIcon: const Icon(
                                          Icons.person_outline_rounded),
                                    ),
                                    validator: (v) =>
                                        (v == null || v.trim().length < 2)
                                            ? t('Enter your full name',
                                                'Ilagay ang iyong buong pangalan')
                                            : null,
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _username,
                                    autocorrect: false,
                                    autofillHints: const [
                                      AutofillHints.newUsername
                                    ],
                                    decoration: InputDecoration(
                                      labelText: t('Username', 'Username'),
                                      hintText: 'juan.delacruz',
                                      prefixIcon: const Icon(Icons.badge_outlined),
                                    ),
                                    validator: (v) {
                                      try {
                                        normalizeUsername(v ?? '');
                                        return null;
                                      } on FormatException {
                                        return t(
                                            '3-20 chars: letters, numbers, "." or "_"',
                                            '3-20 karakter: letra, numero, "." o "_"');
                                      }
                                    },
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _phone,
                                    keyboardType: TextInputType.phone,
                                    autofillHints: const [
                                      AutofillHints.telephoneNumber
                                    ],
                                    decoration: InputDecoration(
                                      labelText: t('Phone number', 'Numero ng Telepono'),
                                      hintText: '09XXXXXXXXX',
                                      prefixIcon: const Icon(Icons.phone_outlined),
                                    ),
                                    validator: (v) {
                                      final digits = (v ?? '')
                                          .replaceAll(RegExp(r'[^0-9]'), '');
                                      return digits.length < 10
                                          ? t('Enter a valid phone number',
                                              'Ilagay ang wastong numero ng telepono')
                                          : null;
                                    },
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _birthdayText,
                                    readOnly: true,
                                    onTap: _pickBirthday,
                                    decoration: InputDecoration(
                                      labelText: t('Birthday', 'Kaarawan'),
                                      hintText: 'MM/DD/YYYY',
                                      prefixIcon: const Icon(Icons.cake_outlined),
                                    ),
                                    validator: (_) => _birthday == null
                                        ? t('Select your birthday',
                                            'Piliin ang iyong kaarawan')
                                        : null,
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _password,
                                    obscureText: _obscurePassword,
                                    autofillHints: const [
                                      AutofillHints.newPassword
                                    ],
                                    decoration: InputDecoration(
                                      labelText: t('Password', 'Password'),
                                      prefixIcon: const Icon(
                                          Icons.lock_outline_rounded),
                                      suffixIcon: IconButton(
                                        icon: Icon(_obscurePassword
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined),
                                        onPressed: () => setState(() =>
                                            _obscurePassword =
                                                !_obscurePassword),
                                      ),
                                    ),
                                    validator: (v) =>
                                        (v == null || v.length < 8)
                                            ? t('At least 8 characters',
                                                'Hindi bababa sa 8 na karakter')
                                            : null,
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _confirmPassword,
                                    obscureText: _obscureConfirm,
                                    autofillHints: const [
                                      AutofillHints.newPassword
                                    ],
                                    decoration: InputDecoration(
                                      labelText:
                                          t('Confirm password', 'Kumpirmahin ang Password'),
                                      prefixIcon: const Icon(
                                          Icons.lock_outline_rounded),
                                      suffixIcon: IconButton(
                                        icon: Icon(_obscureConfirm
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined),
                                        onPressed: () => setState(() =>
                                            _obscureConfirm = !_obscureConfirm),
                                      ),
                                    ),
                                    validator: (v) => v != _password.text
                                        ? t('Passwords don\'t match',
                                            'Hindi magkatugma ang password')
                                        : null,
                                  ),
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 250),
                                    child: _error == null
                                        ? const SizedBox.shrink()
                                        : Padding(
                                            padding:
                                                const EdgeInsets.only(top: 14),
                                            child: Row(
                                              children: [
                                                const Icon(
                                                    Icons.error_outline_rounded,
                                                    color: YosColors.bad,
                                                    size: 18),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(_error!,
                                                      style: const TextStyle(
                                                          color: YosColors.bad,
                                                          fontWeight:
                                                              FontWeight.w600,
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
                                            child: CircularProgressIndicator(
                                                color: YosColors.ink,
                                                strokeWidth: 3),
                                          ),
                                        )
                                      : BreathingGlowButton(
                                          label: t('Create account', 'Gumawa ng Account'),
                                          onPressed: _register,
                                        ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(t('Already have an account? Sign in',
                              'May account ka na? Mag-sign in')),
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
