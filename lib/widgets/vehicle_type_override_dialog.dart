import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../screens/document_scan_screen.dart';
import '../services/locale_controller.dart';
import '../services/registry_service.dart';
import 'app_dialog.dart';
import 'doc_photo_view.dart';
import 'glow_effects.dart';
import 'toast.dart';

/// RFID-scan vehicle-type picker: a driver can have more than one vehicle
/// (different plate, own OR/CR) enrolled under the same card — a tricycle
/// for weekday runs and a truck for hauling, say — so instead of always
/// reusing whichever single vehicle the tag happened to resolve to, this
/// lets the collector pick which of the 4 vehicle types this entry is
/// actually for.
///
/// Picking a type that's already been registered under this tag (see
/// [variants]) swaps straight to *that* vehicle's own plate/driver — staged
/// as a two-step "read this card, confirm" flow so it reads to the
/// collector like the card itself is updating live, even though the tag
/// itself is never written to. Picking a type with nothing saved yet opens
/// a short form to capture its plate number and OR/CR right here, which
/// saves as a brand-new plate-keyed document (see
/// VehicleRegistry.register) sharing the same RFID tag — it never edits or
/// overwrites [current] or any other already-registered type, since each
/// type lives in its own document.
///
/// Returns the resolved [RegisteredVehicle] to build this entry's receipt
/// from, or null if the collector backed out anywhere along the way —
/// callers should treat null as "cancel the scan", not "keep the original
/// vehicle".
Future<RegisteredVehicle?> pickVehicleForRfidTag(
  BuildContext context, {
  required String tag,
  required RegisteredVehicle current,
  required List<RegisteredVehicle> variants,
}) async {
  final byType = <VehicleType, RegisteredVehicle>{
    for (final v in variants) VehicleType.fromLabel(v.vehicleType): v,
  };
  // The scan's own match might not have made it into [variants] (e.g. it
  // was read moments before this variants list — a stale local cache read
  // racing the write isn't impossible), so it's folded in explicitly
  // rather than trusted to already be there.
  byType[VehicleType.fromLabel(current.vehicleType)] = current;

  final choice = await showModalBottomSheet<_PickChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _VehicleTypePickerSheet(
      currentType: VehicleType.fromLabel(current.vehicleType),
      byType: byType,
    ),
  );
  if (choice == null || !context.mounted) return null;

  final existing = choice.vehicle;
  if (existing != null) {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('Use this vehicle?', 'Gamitin ang sasakyang ito?'),
      message: t(
          '${existing.plateNumber} · ${existing.driverName} '
              '(${existing.vehicleType}) for this entry?',
          '${existing.plateNumber} · ${existing.driverName} '
              '(${existing.vehicleType}) para sa entry na ito?'),
      confirmLabel: t('Confirm', 'Kumpirmahin'),
      confirmIcon: Icons.check_rounded,
    );
    return confirmed == true ? existing : null;
  }

  if (!context.mounted) return null;
  return showModalBottomSheet<RegisteredVehicle>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddVehicleTypeSheet(
      tag: tag,
      type: choice.addType!,
      driverName: current.driverName,
      defaultZoneId: current.defaultZoneId,
    ),
  );
}

class _PickChoice {
  const _PickChoice.existing(RegisteredVehicle v)
      : vehicle = v,
        addType = null;
  const _PickChoice.addNew(VehicleType t)
      : vehicle = null,
        addType = t;
  final RegisteredVehicle? vehicle;
  final VehicleType? addType;
}

/// Half-screen, drag-to-resize sheet (not a fixed dialog) — same
/// DraggableScrollableSheet shape ReceiptPreviewDrawer uses elsewhere in
/// this app, so this picker feels consistent with the rest of the
/// scan-to-receipt flow it's staged inside of.
class _VehicleTypePickerSheet extends StatelessWidget {
  const _VehicleTypePickerSheet(
      {required this.currentType, required this.byType});
  final VehicleType currentType;
  final Map<VehicleType, RegisteredVehicle> byType;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
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
            Text(t('Select vehicle type', 'Piliin ang uri ng sasakyan'),
                style: TextStyle(
                    color: YosColors.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 18)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                  t(
                      'This driver\'s other vehicles show their saved plate. '
                          'A new type asks for its details.',
                      'Ang ibang sasakyan ng driver na ito ay ipinapakita ang '
                          'naka-save na plaka. Ang bagong uri ay hihilingin '
                          'ang mga detalye nito.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: YosColors.sub,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
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

  Widget _row(BuildContext context, VehicleType type) {
    final existing = byType[type];
    final selected = type == currentType;
    final hasData = existing != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(
            context,
            hasData
                ? _PickChoice.existing(existing)
                : _PickChoice.addNew(type)),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: selected ? YosColors.accentSoft : YosColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
            border: hasData
                ? null
                : Border.all(
                    color: YosColors.sub.withValues(alpha: 0.35),
                    style: BorderStyle.solid,
                  ),
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
                child: Icon(type.icon,
                    color: selected ? YosColors.onAccent : YosColors.ink,
                    size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(type.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight:
                                selected ? FontWeight.w800 : FontWeight.w600,
                            fontSize: 15)),
                    Text(
                        hasData
                            ? existing.plateNumber
                            : t('Tap to add details', 'I-tap para magdagdag'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: hasData
                                ? YosColors.sub
                                : YosColors.accentDeep,
                            fontWeight: FontWeight.w600,
                            fontSize: 12)),
                  ],
                ),
              ),
              Icon(
                hasData
                    ? Icons.chevron_right_rounded
                    : Icons.add_circle_outline_rounded,
                color: hasData ? YosColors.sub : YosColors.accentDeep,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Short capture form for a vehicle type with nothing saved yet under this
/// RFID tag: plate number (required) and OR/CR photo (optional, same
/// DocumentScanScreen capture VehicleAttachmentScreen uses for OR/CR).
/// Saving registers a brand-new plate-keyed vehicle (driver name and
/// default zone carried over from the vehicle that was actually scanned,
/// since it's the same driver/card) tagged with the same RFID card —
/// [current]'s own document is never touched by this.
class _AddVehicleTypeSheet extends StatefulWidget {
  const _AddVehicleTypeSheet({
    required this.tag,
    required this.type,
    required this.driverName,
    required this.defaultZoneId,
  });

  final String tag;
  final VehicleType type;
  final String driverName;
  final String defaultZoneId;

  @override
  State<_AddVehicleTypeSheet> createState() => _AddVehicleTypeSheetState();
}

class _AddVehicleTypeSheetState extends State<_AddVehicleTypeSheet> {
  final _formKey = GlobalKey<FormState>();
  final _plate = TextEditingController();
  String? _orCrPhotoPath;
  bool _saving = false;

  @override
  void dispose() {
    _plate.dispose();
    super.dispose();
  }

  Future<void> _scanOrCr() async {
    final result = await Navigator.of(context).push<DocumentScanResult>(
      MaterialPageRoute(
        builder: (_) => DocumentScanScreen(
          title: t('Scan OR/CR', 'I-scan ang OR/CR'),
          instructions: t('Align the OR/CR within the frame, then Capture',
              'Ihanay ang OR/CR sa loob ng frame, tapos Capture'),
          portrait: true,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _orCrPhotoPath = result.filePath);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final plate = _plate.text.trim();
      // This plate must not already belong to a different, unrelated
      // vehicle — VehicleRegistry.register keys on plate and merges into
      // whatever document already has that key, so saving over one here
      // would silently corrupt someone else's registered vehicle instead
      // of creating this driver's new one.
      final clash = await VehicleRegistry.instance.lookup(plate);
      if (clash != null) {
        if (!mounted) return;
        Toast.error(
            context,
            t('Plate $plate is already registered to another vehicle.',
                'Naka-rehistro na ang plaka $plate sa ibang sasakyan.'));
        return;
      }
      final saved = await VehicleRegistry.instance.register(
        plateNumber: plate,
        driverName: widget.driverName,
        vehicleType: widget.type.label,
        defaultZoneId: widget.defaultZoneId,
        orCrPhotoPath: _orCrPhotoPath,
        rfidTag: widget.tag,
      );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (e) {
      if (!mounted) return;
      Toast.error(context,
          t("Couldn't save this vehicle: $e", 'Hindi na-save ang sasakyan: $e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: YosColors.bg,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Form(
            key: _formKey,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                        color: YosColors.sub.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                          color: YosColors.mint,
                          borderRadius: BorderRadius.circular(12)),
                      alignment: Alignment.center,
                      child: Icon(widget.type.icon,
                          color: YosColors.ink, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          t('Add ${widget.type.label} details',
                              'Magdagdag ng detalye ng ${widget.type.label}'),
                          style: TextStyle(
                              color: YosColors.ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 16)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                    t(
                        'This card isn\'t registered for this vehicle type '
                            'yet — save it once here and it\'s remembered '
                            'from now on, just like the rest of ${widget.driverName}\'s vehicles.',
                        'Hindi pa naka-rehistro ang card na ito para sa uri ng '
                            'sasakyang ito — i-save ito ngayon at maaalala na '
                            'mula ngayon, tulad ng ibang sasakyan ni ${widget.driverName}.'),
                    style: TextStyle(
                        color: YosColors.sub,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _plate,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: t('Plate number', 'Plaka Numero'),
                    prefixIcon: const Icon(Icons.pin_outlined),
                  ),
                  validator: (v) => (v == null || v.trim().length < 5)
                      ? t('Enter a valid plate number',
                          'Ilagay ang wastong plaka numero')
                      : null,
                ),
                const SizedBox(height: 16),
                Text('OR/CR',
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AspectRatio(
                    aspectRatio: 1.7,
                    child: _orCrPhotoPath == null
                        ? Container(
                            color: YosColors.surfaceHigh,
                            alignment: Alignment.center,
                            child: Icon(Icons.badge_outlined,
                                color: YosColors.sub, size: 32),
                          )
                        : DocPhotoView(path: _orCrPhotoPath, url: null),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _scanOrCr,
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: Text(_orCrPhotoPath == null
                      ? t('Capture OR/CR', 'Kumuha ng OR/CR')
                      : t('Retake', 'Kunin Ulit')),
                ),
                const SizedBox(height: 22),
                _saving
                    ? Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                              color: YosColors.ink, strokeWidth: 3),
                        ),
                      )
                    : BreathingGlowButton(
                        label: t('Save vehicle', 'I-save ang Sasakyan'),
                        icon: Icons.check_rounded,
                        onPressed: _save,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
