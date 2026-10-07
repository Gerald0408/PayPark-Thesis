import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../services/locale_controller.dart';
import '../services/points_settings_service.dart';
import 'toast.dart';

/// Opt-in points redemption at time out, for an RFID-enrolled vehicle.
/// Never auto-applies a discount: [redeemedTier] starts null and only
/// moves when a tier is tapped. Tiers are percentages of [vehicleFee]
/// (kRedemptionTiers), but each one's points cost is flat (see
/// [redemptionPointsCost]), not scaled by the discount.
class RedeemPointsCard extends StatelessWidget {
  const RedeemPointsCard({
    super.key,
    required this.balance,
    required this.redeemedTier,
    required this.vehicleFee,
    required this.vehicleType,
    required this.onChanged,
  });

  final double balance;
  final int? redeemedTier;

  /// This vehicle type's own fee — what each tier percentage discounts
  /// against (e.g. 25% of a ₱100 fee is ₱25 off).
  final double vehicleFee;

  /// Unused by the disabled-tier check now (a percentage can never
  /// exceed the fee it's a share of) — kept as a constructor param since
  /// the caller already has it handy and a future per-vehicle-type
  /// restriction might want it again.
  final String vehicleType;

  /// Null while the sheet is already saved — the tiers freeze once the
  /// transaction has actually been committed.
  final ValueChanged<int?>? onChanged;

  double _discountFor(int tier) => vehicleFee * tier / 100;

  /// Why [tier] can't be selected right now, or null if it can.
  String? _disabledReason(int tier) {
    final cost = redemptionPointsCost(tier);
    if (cost > balance) {
      return t('Needs ${formatPoints(cost - balance)} more points',
          'Kailangan pa ng ${formatPoints(cost - balance)} points');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YosColors.mint,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.loyalty_rounded,
                  color: YosColors.accentDeep, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    t('${formatPoints(balance)} points available',
                        '${formatPoints(balance)} puntos available'),
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tier in kRedemptionTiers)
                Builder(builder: (context) {
                  final reason = _disabledReason(tier);
                  final discount = _discountFor(tier);
                  final chip = ChoiceChip(
                    label: Text(t(
                        '₱${discount.toStringAsFixed(0)} off — Requires '
                            '${formatPoints(redemptionPointsCost(tier))} points',
                        '₱${discount.toStringAsFixed(0)} off — Kailangan ng '
                            '${formatPoints(redemptionPointsCost(tier))} points')),
                    selected: redeemedTier == tier,
                    // Tappable even when unaffordable — rather than a
                    // silently-disabled chip, picking one the balance
                    // can't cover surfaces the Insufficient Points
                    // warning below instead of just doing nothing.
                    onSelected: onChanged == null
                        ? null
                        : (selected) {
                            if (!selected) {
                              onChanged!(null);
                              return;
                            }
                            if (reason != null) {
                              Toast.error(
                                  context, t('Insufficient Points', 'Kulang ang Points'));
                              return;
                            }
                            onChanged!(tier);
                          },
                  );
                  return reason == null
                      ? chip
                      : Opacity(
                          opacity: 0.6,
                          child: Tooltip(message: reason, child: chip),
                        );
                }),
            ],
          ),
          if (redeemedTier != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                  t(
                      '− ₱${_discountFor(redeemedTier!).toStringAsFixed(0)} off this fee',
                      '− ₱${_discountFor(redeemedTier!).toStringAsFixed(0)} bawas sa bayad'),
                  style: TextStyle(
                      color: YosColors.accentDeep,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }
}

