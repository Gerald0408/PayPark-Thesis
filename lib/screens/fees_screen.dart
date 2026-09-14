import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/glow_effects.dart';

class FeesScreen extends StatefulWidget {
  const FeesScreen({super.key});

  @override
  State<FeesScreen> createState() => _FeesScreenState();
}

class _FeesScreenState extends State<FeesScreen> {
  // Captured once for this screen's whole lifetime — StreamBuilder below
  // must see the same Stream instance across every rebuild (fee edits
  // trigger rebuilds via _onFeesChanged), not a fresh one re-read from the
  // getter each time. See YosRepository.currentUserIsAdmin's doc comment.
  late final Stream<bool> _isAdminStream =
      YosRepository.instance.currentUserIsAdmin;

  @override
  void initState() {
    super.initState();
    FeeSettingsService.instance.addListener(_onFeesChanged);
  }

  void _onFeesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FeeSettingsService.instance.removeListener(_onFeesChanged);
    super.dispose();
  }

  Future<void> _editFee(VehicleType type) async {
    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) => _EditFeeDialog(type: type),
    );
    if (result == null) return;
    if (result <= 0) {
      if (mounted) {
        Toast.error(context, t('Enter a valid amount.', 'Ilagay ang tamang halaga.'));
      }
      return;
    }
    // Was a bare `await` with no try/catch: a denied write (e.g. Firestore
    // rules rejecting it — settings/fees requires isAdmin(), which itself
    // requires Face ID enrolled, not just is_admin true) got silently
    // rolled back by Firestore's own optimistic-write revert, with no
    // toast either way — the dialog just closed and the rate quietly
    // snapped back to its old value, with nothing on screen explaining
    // why. Surfacing the failure here at least makes that visible instead
    // of a rate edit that looks like it did nothing.
    try {
      await FeeSettingsService.instance.setFee(type, result);
      if (mounted) {
        Toast.success(
            context,
            t(
                '${type.label} fee updated to ₱${result.toStringAsFixed(0)}',
                'Na-update ang bayad para sa ${type.label} sa '
                    '₱${result.toStringAsFixed(0)}'));
      }
    } catch (_) {
      if (mounted) {
        Toast.error(
            context,
            t("Couldn't update ${type.label} — try again.",
                'Hindi na-update ang ${type.label} — subukan ulit.'));
      }
    }
  }

  /// Tapping any fee row — admin or not — opens this details view first,
  /// showing the vehicle type, current rate, and (once it's been edited at
  /// least once) the rate it replaced and when. Editing itself stays
  /// admin-only, reached from a button inside the dialog rather than the
  /// row tap directly, so a view-only account can still see the same
  /// history an admin sees.
  Future<void> _showFeeDetails(VehicleType type, bool isAdmin) async {
    final editRequested = await showDialog<bool>(
      context: context,
      builder: (dialogContext) =>
          _FeeDetailsDialog(type: type, isAdmin: isAdmin),
    );
    if (editRequested == true) await _editFee(type);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Fee Matrix', 'Talaan ng Bayad'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<bool>(
            stream: _isAdminStream,
            initialData: false,
            builder: (context, snap) {
              final isAdmin = snap.data ?? false;
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  PopIn(
                    child: GlassCard(
                      color: isAdmin ? YosColors.mint : YosColors.pistachio,
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                              isAdmin ? Icons.edit_rounded : Icons.lock_rounded,
                              color: YosColors.ink,
                              size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              isAdmin
                                  ? t(
                                      'Rates fixed by $kOrdinanceRef. Tap a rate to update it — changes sync to every device.',
                                      'Naka-fix ang mga bayad ayon sa $kOrdinanceRef. I-tap ang isang rate para i-update ito — nag-sync ang mga pagbabago sa lahat ng device.')
                                  : t(
                                      'Rates fixed by $kOrdinanceRef. View only — ask an admin for changes.',
                                      'Naka-fix ang mga bayad ayon sa $kOrdinanceRef. Tingin lang — magtanong sa admin para sa mga pagbabago.'),
                              style: TextStyle(
                                  color: YosColors.ink,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < VehicleType.values.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: PopIn(
                        delayMs: 80 + i * 60,
                        child: GlassCard(
                          onTap: () =>
                              _showFeeDetails(VehicleType.values[i], isAdmin),
                          child: Row(
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                    color: YosColors.mint,
                                    borderRadius: BorderRadius.circular(18)),
                                child: Icon(VehicleType.values[i].icon,
                                    color: YosColors.ink, size: 28),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(VehicleType.values[i].label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: YosColors.ink,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 16)),
                                    ),
                                    if (FeeSettingsService.instance
                                        .hasOverride(VehicleType.values[i]))
                                      Padding(
                                        padding: const EdgeInsets.only(left: 8),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                              color: YosColors.seafoam,
                                              borderRadius:
                                                  BorderRadius.circular(999)),
                                          child: Text(t('Updated', 'Na-update'),
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w800,
                                                  color: YosColors.ink)),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                      '₱${FeeSettingsService.instance.feeFor(VehicleType.values[i]).toStringAsFixed(0)}',
                                      maxLines: 1,
                                      style: text.displayLarge
                                          ?.copyWith(fontSize: 30)),
                                ),
                              ),
                              if (isAdmin) ...[
                                const SizedBox(width: 6),
                                Icon(Icons.edit_rounded,
                                    color: YosColors.sub, size: 18),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Read-only fee history for one vehicle type — reached by tapping its row
/// on FeesScreen. Shows the type, its current rate, and (once
/// [FeeSettingsService.hasOverride] is true for it) the rate it replaced
/// and when the edit happened, pulled from the same settings/fees doc
/// [FeeSettingsService.setFee] stamps on every edit — no separate audit-log
/// query needed. Popping `true` (the "Edit rate" button, admin only) tells
/// FeesScreen's [_showFeeDetails] to chain straight into [_EditFeeDialog].
class _FeeDetailsDialog extends StatelessWidget {
  const _FeeDetailsDialog({required this.type, required this.isAdmin});
  final VehicleType type;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final fees = FeeSettingsService.instance;
    final current = fees.feeFor(type);
    final previous = fees.previousFeeFor(type);
    final updatedAt = fees.updatedAtFor(type);
    final money = NumberFormat.currency(symbol: '₱', decimalDigits: 0);

    return Dialog(
      backgroundColor: YosColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: YosColors.mint,
                      borderRadius: BorderRadius.circular(14)),
                  child: Icon(type.icon, color: YosColors.ink, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(type.label,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: YosColors.ink)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close_rounded, color: YosColors.sub),
                  tooltip: t('Close', 'Isara'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (previous != null)
                  _detailRow(
                      t('Previous price', 'Dating Presyo'), money.format(previous)),
                _detailRow(
                    t('Current rate', 'Kasalukuyang Bayad'), money.format(current)),
                if (updatedAt != null)
                  _detailRow(t('Updated', 'Na-update'),
                      DateFormat('MMM d, y \'at\' h:mm a').format(updatedAt)),
                if (previous == null && updatedAt == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      t('Still the $kOrdinanceRef default — never edited.',
                          'Ito pa rin ang default ng $kOrdinanceRef — hindi pa na-e-edit.'),
                      style: TextStyle(color: YosColors.sub, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          if (isAdmin)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Material(
                color: YosColors.accent,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  onTap: () => Navigator.pop(context, true),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_rounded,
                            size: 18, color: YosColors.onAccent),
                        const SizedBox(width: 8),
                        Text(t('Edit rate', 'I-edit ang Bayad'),
                            style: TextStyle(
                                color: YosColors.onAccent,
                                fontWeight: FontWeight.w800,
                                fontSize: 15)),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    color: YosColors.sub,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            Text(value,
                style: TextStyle(
                    color: YosColors.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 14)),
          ],
        ),
      );
}

/// Content of the fee-edit dialog, split out so it can own its
/// [TextEditingController] itself — disposed only in this widget's own
/// [dispose], i.e. once the dialog route's element actually unmounts
/// after its closing animation finishes. The controller used to be
/// created by [_FeesScreenState._editFee] and disposed the instant
/// showDialog's Future resolved, which happens as soon as the route is
/// popped — while the TextField was still on-screen mid-fade-out for
/// the dialog's exit transition. That threw "A TextEditingController
/// was used after being disposed" mid-build, which cascaded into the
/// widgets-library "'_dependents.isEmpty': is not true" assertion (a
/// red screen) as a secondary failure.
class _EditFeeDialog extends StatefulWidget {
  const _EditFeeDialog({required this.type});
  final VehicleType type;

  @override
  State<_EditFeeDialog> createState() => _EditFeeDialogState();
}

class _EditFeeDialogState extends State<_EditFeeDialog> {
  late final _amount = TextEditingController(
      text: FeeSettingsService.instance.feeFor(widget.type).toStringAsFixed(0));

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: YosColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                      t('Edit ${widget.type.label} fee',
                          'I-edit ang bayad para sa ${widget.type.label}'),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: YosColors.ink)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close_rounded, color: YosColors.sub),
                  tooltip: t('Cancel', 'Kanselahin'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: TextField(
              controller: _amount,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixText: '₱ '),
              onSubmitted: (v) =>
                  Navigator.pop(context, double.tryParse(v.trim())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Material(
              color: YosColors.accent,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: () => Navigator.pop(
                    context, double.tryParse(_amount.text.trim())),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  alignment: Alignment.center,
                  child: Text(t('Save', 'I-save'),
                      style: TextStyle(
                          color: YosColors.onAccent,
                          fontWeight: FontWeight.w800,
                          fontSize: 15)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
