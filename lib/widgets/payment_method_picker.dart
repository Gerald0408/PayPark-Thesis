import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/locale_controller.dart';

/// Cash / GCash / Maya choice for the receipt, plus the reference-number
/// field a digital payment needs. Large tap targets on purpose — this is
/// tapped at the curb, often by older collectors. Disabled ([onChanged]
/// null) once the payment is being saved.
class PaymentMethodPicker extends StatelessWidget {
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
                    color: m == method
                        ? YosColors.accent
                        : YosColors.surface,
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
          TextField(
            controller: refController,
            enabled: enabled,
            keyboardType: TextInputType.number,
            onChanged: (_) => onRefChanged(),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              labelText: t('${PaymentMethod.label(method)} reference no.',
                  'Reference no. ng ${PaymentMethod.label(method)}'),
              helperText: t("Copy it from the driver's payment screen",
                  'Kopyahin mula sa payment screen ng driver'),
              prefixIcon: const Icon(Icons.tag_rounded),
            ),
          ),
        ],
      ],
    );
  }
}

