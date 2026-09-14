import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../services/locale_controller.dart';
import '../services/registry_service.dart';
import '../widgets/doc_photo_view.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import 'registry_screen.dart';

/// Read-only look at a registered vehicle — full name, vehicle type,
/// default zone, and the two captured document photos shown directly on
/// the page (not hidden behind a "View photo" tap the way the edit form
/// does it). RegistryScreen's list routes here on a plain tap; editing is
/// its own explicit action (the pencil icon there, or the button at the
/// bottom of this screen) rather than the same tap doing both, so looking
/// something up doesn't risk an accidental field change.
class VehicleDetailScreen extends StatefulWidget {
  const VehicleDetailScreen({super.key, required this.vehicle});

  final RegisteredVehicle vehicle;

  @override
  State<VehicleDetailScreen> createState() => _VehicleDetailScreenState();
}

class _VehicleDetailScreenState extends State<VehicleDetailScreen> {
  late RegisteredVehicle _vehicle;

  @override
  void initState() {
    super.initState();
    _vehicle = widget.vehicle;
    _syncPhotosIfNeeded();
  }

  /// Self-heals a vehicle registered before cross-device photo sync
  /// existed: such a vehicle only ever got a local file path saved, never
  /// a Storage URL, so its photo only ever showed up on the exact device
  /// that captured it (see VehicleRegistry.backfillPhotoSync). If that
  /// device is the one open right now, this silently syncs it and
  /// refreshes the screen so the photo appears immediately instead of the
  /// collector having to know to back out, edit, and re-save it. A no-op
  /// (and this screen never notices) for a vehicle that's already synced,
  /// or whose local file isn't on this device.
  Future<void> _syncPhotosIfNeeded() async {
    final needsSync = (_vehicle.driverLicensePhotoPath != null &&
            _vehicle.driverLicensePhotoUrl == null) ||
        (_vehicle.orCrPhotoPath != null && _vehicle.orCrPhotoUrl == null);
    if (!needsSync) return;
    await VehicleRegistry.instance.backfillPhotoSync(_vehicle);
    if (!mounted) return;
    final fresh = await VehicleRegistry.instance.lookup(_vehicle.plateNumber);
    if (fresh != null && mounted) setState(() => _vehicle = fresh);
  }

  void _edit(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RegisterVehicleScreen(existing: _vehicle)));
  }

  void _viewPhoto(BuildContext context, String? path, String? url) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4,
            child: DocPhotoView(path: path, url: url, fit: BoxFit.contain),
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = _vehicle;
    final vt = VehicleType.fromLabel(vehicle.vehicleType);
    final zone = kZones.firstWhere((z) => z.id == vehicle.defaultZoneId,
        orElse: () => kZones.first);
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Vehicle details', 'Detalye ng Sasakyan'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              PopIn(
                child: GlassCard(
                  child: Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                            color: YosColors.mint,
                            borderRadius: BorderRadius.circular(16)),
                        child: Icon(vt.icon, color: YosColors.ink, size: 26),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(vehicle.plateNumber,
                                style: TextStyle(
                                    color: YosColors.ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18,
                                    letterSpacing: 1.2)),
                            Text(
                                t(
                                    'registered ${DateFormat('MMM d, y').format(vehicle.registeredAt)}',
                                    'narehistro noong ${DateFormat('MMM d, y').format(vehicle.registeredAt)}'),
                                style: TextStyle(
                                    color: YosColors.sub,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              PopIn(
                delayMs: 80,
                child: GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _DetailRow(
                          label: t('Full name', 'Buong Pangalan'),
                          value: vehicle.driverName),
                      const Divider(height: 20),
                      _DetailRow(
                          label: t('Vehicle type', 'Uri ng Sasakyan'),
                          value: vt.label),
                      const Divider(height: 20),
                      _DetailRow(
                          label: t('Default zone', 'Default na Zone'),
                          value: zone.name),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              PopIn(
                delayMs: 140,
                child: GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('Documents', 'Mga Dokumento'),
                          style: TextStyle(
                              color: YosColors.ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 16)),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _DocPhoto(
                              label: t("Driver's license", "Driver's License"),
                              path: vehicle.driverLicensePhotoPath,
                              url: vehicle.driverLicensePhotoUrl,
                              onTap: (vehicle.driverLicensePhotoPath ??
                                          vehicle.driverLicensePhotoUrl) ==
                                      null
                                  ? null
                                  : () => _viewPhoto(
                                      context,
                                      vehicle.driverLicensePhotoPath,
                                      vehicle.driverLicensePhotoUrl),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _DocPhoto(
                              label: 'OR/CR',
                              path: vehicle.orCrPhotoPath,
                              url: vehicle.orCrPhotoUrl,
                              onTap: (vehicle.orCrPhotoPath ??
                                          vehicle.orCrPhotoUrl) ==
                                      null
                                  ? null
                                  : () => _viewPhoto(
                                      context,
                                      vehicle.orCrPhotoPath,
                                      vehicle.orCrPhotoUrl),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              BreathingGlowButton(
                label: t('Edit vehicle', 'I-edit ang Sasakyan'),
                icon: Icons.edit_outlined,
                onPressed: () => _edit(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: TextStyle(
                  color: YosColors.sub,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(value.isEmpty ? '—' : value,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

/// Document photo tile — the captured image itself (tap to zoom) or a
/// plain "Not captured" placeholder if that document was never scanned.
class _DocPhoto extends StatelessWidget {
  const _DocPhoto(
      {required this.label, required this.path, required this.url, this.onTap});
  final String label;
  final String? path;
  final String? url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = path != null || url != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: YosColors.sub)),
        const SizedBox(height: 6),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 1.4,
              child: hasPhoto
                  ? DocPhotoView(path: path, url: url)
                  : Container(
                      color: YosColors.surfaceHigh,
                      alignment: Alignment.center,
                      child: Text(t('Not captured', 'Hindi Nakuha'),
                          style: TextStyle(
                              color: YosColors.sub,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
