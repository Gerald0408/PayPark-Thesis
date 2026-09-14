import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import 'app_dialog.dart';

/// RFID-scan vehicle-type override — cosmetic only (the tag itself is
/// never written to; this just lets the collector pick a different
/// [VehicleType] than the one the enrolled vehicle is registered under
/// before the receipt for *this one entry* is built), but staged as a
/// two-step "the reader read this, confirm the write" flow so it reads to
/// the collector like the card itself is being updated.
///
/// Returns the confirmed [VehicleType], or null if the collector backed
/// out at either step — callers should treat null as "cancel the scan",
/// not "keep the original type".
Future<VehicleType?> confirmVehicleTypeOverride(
  BuildContext context, {
  required VehicleType current,
}) async {
  final picked = await showModalBottomSheet<VehicleType>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _VehicleTypePickerSheet(current: current),
  );
  if (picked == null || !context.mounted) return null;

  final confirmed = await showAppConfirmDialog(
    context,
    title: 'Write vehicle type?',
    message:
        'Set this card\'s vehicle type to "${picked.label}" for this entry?',
    confirmLabel: 'Confirm',
    confirmIcon: Icons.check_rounded,
  );
  return confirmed == true ? picked : null;
}

/// Half-screen, drag-to-resize sheet (not a fixed dialog) — same
/// DraggableScrollableSheet shape ReceiptPreviewDrawer uses elsewhere in
/// this app, so this picker feels consistent with the rest of the
/// scan-to-receipt flow it's staged inside of. Plain leading-icon rows,
/// nothing on the trailing side — the current type is called out with a
/// tinted row and bold label instead of a trailing checkmark/button.
class _VehicleTypePickerSheet extends StatelessWidget {
  const _VehicleTypePickerSheet({required this.current});
  final VehicleType current;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: YosColors.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                  color: YosColors.sub.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(height: 14),
            Text('Select vehicle type',
                style: TextStyle(
                    color: YosColors.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 18)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                children: [
                  for (final t in VehicleType.values) _row(context, t),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, VehicleType t) {
    final selected = t == current;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, t),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: selected ? YosColors.accentSoft : YosColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: selected ? YosColors.accentDeep : YosColors.mint,
                    borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: Icon(t.icon,
                    color: selected ? YosColors.onAccent : YosColors.ink,
                    size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(t.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                        fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
