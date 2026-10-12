import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../services/locale_controller.dart';
import '../services/nfc_link_service.dart';

/// "Hold the card to the phone" step that writes the driver portal link
/// onto a driver's NFC card (see NfcLinkService) — after this, tapping the
/// card on the driver's own phone opens the portal with the card number
/// filled in. Uses the phone's built-in NFC, not the USB reader.
class NfcWriteDialog extends StatefulWidget {
  const NfcWriteDialog({super.key, required this.rfidTag});

  final String rfidTag;

  @override
  State<NfcWriteDialog> createState() => _NfcWriteDialogState();
}

enum _Stage { checking, waiting, done, failed }

class _NfcWriteDialogState extends State<NfcWriteDialog> {
  _Stage _stage = _Stage.checking;
  String? _error;

  /// What gets written to the card, shown for copying when writing fails.
  String get _link => NfcLinkService.portalLinkFor(widget.rfidTag).toString();

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    if (_stage == _Stage.waiting) NfcLinkService.instance.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _stage = _Stage.checking;
      _error = null;
    });
    if (!await NfcLinkService.instance.isAvailable()) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        // iPhone NFC is always on; it's "unavailable" only in the free-Apple-ID
        // AltStore build, which has no NFC permission (see codemagic.yaml).
        _error = defaultTargetPlatform == TargetPlatform.iOS
            ? t(
                "This iPhone build can't write NFC cards. Copy the link "
                    'below, open the free "NFC Tools" app → Write → Add a '
                    'record → URL / URI, paste it, then tap Write and hold '
                    'the card to the phone.',
                'Hindi kayang mag-write ng NFC card ang build na ito sa '
                    'iPhone. Kopyahin ang link sa ibaba, buksan ang libreng '
                    '"NFC Tools" app → Write → Add a record → URL / URI, '
                    'i-paste ito, tapos pindutin ang Write at ilapit ang card.')
            : t(
                "This phone's NFC is off or not available. Turn on NFC in "
                    'Settings, then try again.',
                'Naka-off o walang NFC ang phone na ito. I-on ang NFC sa '
                    'Settings, tapos subukan ulit.');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.waiting);
    try {
      await NfcLinkService.instance.writePortalLink(widget.rfidTag,
          iosAlertMessage: t('Hold the driver card near the top of the phone',
              'Ilapit ang card ng driver sa itaas ng phone'));
      HapticFeedback.mediumImpact();
      if (mounted) setState(() => _stage = _Stage.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, title, body) = switch (_stage) {
      _Stage.checking || _Stage.waiting => (
          Icons.contactless_rounded,
          YosColors.accent,
          t('Hold the card to the phone', 'Ilapit ang card sa phone'),
          t(
              "Hold the driver's card flat against the back of this phone "
                  'and keep it still until it says done.',
              'Idikit ang card ng driver sa likod ng phone na ito at huwag '
                  'galawin hanggang lumabas ang "tapos".'),
        ),
      _Stage.done => (
          Icons.check_circle_rounded,
          YosColors.good,
          t('Card ready', 'Handa na ang card'),
          t(
              'Tapping this card on any NFC phone now opens the driver '
                  'portal (${NfcLinkService.portalUrl}). The card still '
                  'works on the USB reader as before.',
              'Kapag itinapat ang card na ito sa kahit anong phone na may '
                  'NFC, magbubukas ang driver portal '
                  '(${NfcLinkService.portalUrl}). Gumagana pa rin ang card '
                  'sa USB reader gaya ng dati.'),
        ),
      _Stage.failed => (
          Icons.error_outline_rounded,
          YosColors.bad,
          t("Couldn't write the card", 'Hindi na-write ang card'),
          _error ?? '',
        ),
    };
    return AlertDialog(
      title: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(title)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(body, style: TextStyle(color: YosColors.sub)),
          if (_stage == _Stage.waiting) ...[
            const SizedBox(height: 18),
            Center(child: CircularProgressIndicator(color: YosColors.accent)),
          ],
          const SizedBox(height: 12),
          Text('${t('Card', 'Card')}: ${widget.rfidTag}',
              style: TextStyle(
                  color: YosColors.ink, fontWeight: FontWeight.w700)),
          if (_stage == _Stage.failed) ...[
            const SizedBox(height: 8),
            SelectableText(_link,
                style: TextStyle(color: YosColors.ink, fontSize: 12)),
          ],
        ],
      ),
      actions: [
        if (_stage == _Stage.failed)
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _link));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(t('Link copied', 'Nakopya ang link'))));
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(t('Copy link', 'Kopyahin ang link')),
          ),
        if (_stage == _Stage.failed)
          TextButton(onPressed: _start, child: Text(t('Try again', 'Subukan ulit'))),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_stage == _Stage.done),
          child: Text(_stage == _Stage.done
              ? t('Done', 'Tapos')
              : t('Cancel', 'Kanselahin')),
        ),
      ],
    );
  }
}
