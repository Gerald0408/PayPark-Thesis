import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/locale_controller.dart';
import '../services/payment_ref_ocr.dart';
import 'toast.dart';

/// Cash / GCash / Maya choice for the receipt, plus the reference-number
/// field a digital payment needs. Large tap targets on purpose — this is
/// tapped at the curb, often by older collectors. Disabled ([onChanged]
/// null) once the payment is being saved. "Scan" photographs the
/// driver's payment screen and fills the reference number in from it.
class PaymentMethodPicker extends StatefulWidget {
  const PaymentMethodPicker({
    super.key,
    required this.method,
    required this.refController,
    required this.onChanged,
    required this.onRefChanged,
  });

  final String method;
  final TextEditingController refController;
  final ValueChanged<String>? onChanged;
  final VoidCallback onRefChanged;

  @override
  State<PaymentMethodPicker> createState() => _PaymentMethodPickerState();
}

class _PaymentMethodPickerState extends State<PaymentMethodPicker> {
  bool _scanning = false;

  String get method => widget.method;
  TextEditingController get refController => widget.refController;
  ValueChanged<String>? get onChanged => widget.onChanged;
  VoidCallback get onRefChanged => widget.onRefChanged;

  /// Photographs the driver's GCash / Maya "sent" screen, reads it on the
  /// device and drops the reference number into the field (which feeds
  /// the receipt). Still editable — the collector checks it against the
  /// driver's screen before confirming payment.
  Future<void> _scan() async {
    final label = PaymentMethod.label(method);
    // The manifest declares CAMERA, so Android refuses the camera intent
    // until the permission is granted.
    if (!(await Permission.camera.request()).isGranted) {
      if (mounted) {
        Toast.warn(
            context,
            t('Camera permission is needed to scan.',
                'Kailangan ang camera para mag-scan.'));
      }
      return;
    }
    final photo = await ImagePicker()
        .pickImage(source: ImageSource.camera, imageQuality: 90);
    if (photo == null || !mounted) return;
    setState(() => _scanning = true);
    String? ref;
    try {
      final tr = TextRecognizer(script: TextRecognitionScript.latin);
      try {
        final read = await tr.processImage(InputImage.fromFilePath(photo.path));
        ref = PaymentRefOcr.parse(read.text);
      } finally {
        await tr.close();
        File(photo.path).delete().ignore();
      }
    } catch (e) {
      if (mounted) {
        Toast.failure(context, t("Couldn't read the photo.", 'Hindi mabasa ang litrato.'), e);
      }
    }
    if (!mounted) return;
    setState(() => _scanning = false);
    if (ref == null) {
      Toast.warn(
          context,
          t('No reference number found. Retake the photo closer, or type it.',
              'Walang nakitang reference number. Kumuha ulit nang mas malapit, o i-type ito.'));
      return;
    }
    refController.text = ref;
    onRefChanged();
    Toast.success(
        context,
        t('$label reference: $ref — check it matches.',
            'Reference ng $label: $ref — tiyaking tugma.'));
  }

  static IconData _icon(String m) => switch (m) {
        PaymentMethod.cash => Icons.payments_rounded,
        _ => Icons.phone_iphone_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final digital = method != PaymentMethod.cash;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t('Payment Method', 'Paraan ng Pagbabayad'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: YosColors.sub,
                fontWeight: FontWeight.w700,
                fontSize: 14)),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final m in PaymentMethod.all)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Material(
                    color: m == method ? YosColors.accent : YosColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: enabled ? () => onChanged!(m) : null,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 56),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: m == method
                                  ? YosColors.accentDeep
                                  : YosColors.glassBorder,
                              width: m == method ? 2 : 1),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_icon(m),
                                size: 20,
                                color: m == method
                                    ? YosColors.onAccent
                                    : YosColors.sub),
                            const SizedBox(height: 4),
                            Text(PaymentMethod.label(m),
                                style: TextStyle(
                                    color: m == method
                                        ? YosColors.onAccent
                                        : YosColors.ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (digital) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: refController,
                  enabled: enabled && !_scanning,
                  // Maya references have letters, so not a number pad.
                  keyboardType: TextInputType.visiblePassword,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => onRefChanged(),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    labelText: t('${PaymentMethod.label(method)} reference no.',
                        'Reference no. ng ${PaymentMethod.label(method)}'),
                    helperText: t(
                        "Tap Scan to read it from the driver's payment screen",
                        'I-tap ang Scan para basahin mula sa payment screen ng driver'),
                    helperMaxLines: 2,
                    prefixIcon: const Icon(Icons.tag_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 58,
                child: FilledButton.icon(
                  onPressed: (enabled && !_scanning) ? _scan : null,
                  icon: _scanning
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.photo_camera_rounded),
                  label: Text(t('Scan', 'Scan'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
