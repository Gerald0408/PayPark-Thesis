import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/driver_account_service.dart';
import '../services/error_log_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import 'toast.dart';

/// Collector-side setup of a driver's portal access: the driver chooses a
/// 6-digit PIN (typed twice), which becomes their sign-in with their RFID
/// card number. Running it again for the same card issues a new PIN and
/// cuts off the old one — that's the "forgot my PIN" path.
class DriverPinDialog extends StatefulWidget {
  const DriverPinDialog(
      {super.key, required this.rfidTag, required this.driverName});

  final String rfidTag;
  final String driverName;

  @override
  State<DriverPinDialog> createState() => _DriverPinDialogState();
}

class _DriverPinDialogState extends State<DriverPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool? _hasAccess;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    DriverAccountService.instance
        .hasAccess(widget.rfidTag)
        .then((v) => mounted ? setState(() => _hasAccess = v) : null)
        .catchError((_) => mounted ? setState(() => _hasAccess = false) : null);
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pin = _pin.text.trim();
    if (!DriverAccountService.isValidPin(pin)) {
      setState(() => _error = t('The PIN must be exactly 6 digits.',
          'Dapat eksaktong 6 na numero ang PIN.'));
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error =
          t("The two PINs don't match.", 'Hindi magkapareho ang dalawang PIN.'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await DriverAccountService.instance.setPin(
          rfidTag: widget.rfidTag, driverName: widget.driverName, pin: pin);
      YosRepository.instance.logAudit(AuditAction.driverPortalPin,
          '${_hasAccess == true ? 'Reset' : 'Set up'} Driver Portal PIN for '
          '${widget.driverName} (Card ${widget.rfidTag})');
      if (!mounted) return;
      Navigator.of(context).pop();
      Toast.success(
          context,
          t('Portal access ready. Sign in at $kDriverPortalUrl',
              'Handa na ang portal. Mag-sign in sa $kDriverPortalUrl'));
    } catch (e, st) {
      ErrorLogService.instance.record(e, st, where: 'set driver PIN');
      if (mounted) {
        setState(() {
          _saving = false;
          _error = t("Couldn't save the PIN. Check the internet and try again.",
              'Hindi na-save ang PIN. Tingnan ang internet at subukan ulit.');
        });
      }
    }
  }

  InputDecoration _pinDecoration(String label) => InputDecoration(
        labelText: label,
        counterText: '',
        prefixIcon: const Icon(Icons.pin_rounded),
      );

  @override
  Widget build(BuildContext context) {
    final pinField = (TextEditingController c, String label) => TextField(
          controller: c,
          enabled: !_saving,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: DriverAccountService.pinLength,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
              fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w700),
          decoration: _pinDecoration(label),
        );

    return AlertDialog(
      backgroundColor: YosColors.surface,
      title: Text(t('Driver Portal PIN', 'PIN para sa driver portal'),
          style: TextStyle(color: YosColors.ink, fontWeight: FontWeight.w800)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                t(
                    '${widget.driverName} signs in at $kDriverPortalUrl with '
                        'card ${widget.rfidTag} and this PIN. Let the driver '
                        'type it themselves.',
                    'Mag-sign in si ${widget.driverName} sa $kDriverPortalUrl '
                        'gamit ang card ${widget.rfidTag} at ang PIN na ito. '
                        'Hayaang ang driver mismo ang mag-type.'),
                style: TextStyle(color: YosColors.ink, fontSize: 15)),
            if (_hasAccess == true) ...[
              const SizedBox(height: 10),
              Text(
                  t('This card already has a PIN. Saving a new one replaces it.',
                      'May PIN na ang card na ito. Papalitan ito ng bagong PIN.'),
                  style: TextStyle(
                      color: YosColors.warn,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
            ],
            const SizedBox(height: 14),
            pinField(_pin, t('New 6-digit PIN', 'Bagong 6-digit PIN')),
            const SizedBox(height: 8),
            pinField(_confirm, t('Type the PIN again', 'I-type ulit ang PIN')),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(
                      color: YosColors.bad, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(t('Cancel', 'Kanselahin')),
        ),
        FilledButton(
          onPressed: _saving || _hasAccess == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_hasAccess == true
                  ? t('Replace PIN', 'Palitan ang PIN')
                  : t('Save PIN', 'I-save ang PIN')),
        ),
      ],
    );
  }
}
