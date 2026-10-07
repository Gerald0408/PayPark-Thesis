import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../services/driver_account_service.dart';
import '../services/locale_controller.dart';
import 'language_toggle.dart';

/// Driver portal sign-in: RFID card number + 6-digit PIN. Big fields and
/// plain wording — many drivers are older and on small phones.
class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  final _card = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  bool _showPin = false;
  String? _error;

  @override
  void dispose() {
    _card.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DriverAccountService.instance
          .signIn(_card.text, _pin.text.trim());
      // authStateChanges in main_driver.dart swaps to the home screen.
    } on DriverLoginException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const big = TextStyle(fontSize: 22, fontWeight: FontWeight.w700);
    return Scaffold(
      backgroundColor: YosColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(
                        alignment: Alignment.centerRight,
                        child: LanguageToggle()),
                    const SizedBox(height: 8),
                    Image.asset('assets/icon/logo.png', height: 96),
                    const SizedBox(height: 16),
                    Text(t('PayPark Driver', 'PayPark Driver'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontSize: 30,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(
                        t('See your points and parking history.',
                            'Tingnan ang iyong points at kasaysayan ng paradahan.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: YosColors.sub, fontSize: 18)),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _card,
                      enabled: !_busy,
                      style: big,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      decoration: InputDecoration(
                        labelText: t('RFID card number', 'Numero ng RFID card'),
                        helperText: t('The number printed on your card',
                            'Ang numerong nakasulat sa card mo'),
                        prefixIcon: const Icon(Icons.credit_card_rounded),
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _pin,
                      enabled: !_busy,
                      obscureText: !_showPin,
                      keyboardType: TextInputType.number,
                      maxLength: DriverAccountService.pinLength,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _signIn(),
                      style: big.copyWith(letterSpacing: 8),
                      decoration: InputDecoration(
                        labelText: t('6-digit PIN', '6-digit na PIN'),
                        counterText: '',
                        prefixIcon: const Icon(Icons.pin_rounded),
                        suffixIcon: IconButton(
                          tooltip: _showPin
                              ? t('Hide PIN', 'Itago ang PIN')
                              : t('Show PIN', 'Ipakita ang PIN'),
                          onPressed: () => setState(() => _showPin = !_showPin),
                          icon: Icon(_showPin
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: YosColors.bad.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(_error!,
                            style: TextStyle(
                                color: YosColors.bad,
                                fontSize: 17,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 60,
                      child: FilledButton(
                        onPressed: _busy ? null : _signIn,
                        child: _busy
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 3))
                            : Text(t('Sign In', 'Mag-sign in'),
                                style: const TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.w800)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                        t(
                            'No PIN yet, or forgot it? Ask any PayPark '
                                'collector to set one up for your card.',
                            'Wala pang PIN o nakalimutan? Magpaset-up sa '
                                'kahit sinong PayPark collector.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: YosColors.sub, fontSize: 16)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
