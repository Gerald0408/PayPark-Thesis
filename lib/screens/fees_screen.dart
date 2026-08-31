import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
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
      if (mounted) Toast.error(context, 'Enter a valid amount.');
      return;
    }
    await FeeSettingsService.instance.setFee(type, result);
    if (mounted) {
      Toast.success(context,
          '${type.label} fee updated to ₱${result.toStringAsFixed(0)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Fee matrix',
            style: TextStyle(fontWeight: FontWeight.w800)),
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
                              isAdmin
                                  ? Icons.edit_rounded
                                  : Icons.lock_rounded,
                              color: YosColors.ink,
                              size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              isAdmin
                                  ? 'Rates fixed by $kOrdinanceRef. Tap a rate to update it — changes sync to every device.'
                                  : 'Rates fixed by $kOrdinanceRef. View only — ask an admin for changes.',
                              style: const TextStyle(
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
                          onTap: isAdmin
                              ? () => _editFee(VehicleType.values[i])
                              : null,
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
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 16)),
                                    ),
                                    if (FeeSettingsService.instance
                                        .hasOverride(VehicleType.values[i]))
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(left: 8),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                              color: YosColors.seafoam,
                                              borderRadius:
                                                  BorderRadius.circular(999)),
                                          child: const Text('Updated',
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
                                const Icon(Icons.edit_rounded,
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
    return AlertDialog(
      title: Text('Edit ${widget.type.label} fee'),
      content: TextField(
        controller: _amount,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(prefixText: '₱ '),
        onSubmitted: (v) => Navigator.pop(context, double.tryParse(v.trim())),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, double.tryParse(_amount.text.trim())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
