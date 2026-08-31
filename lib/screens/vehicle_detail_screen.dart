import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
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
class VehicleDetailScreen extends StatelessWidget {
  const VehicleDetailScreen({super.key, required this.vehicle});

  final RegisteredVehicle vehicle;

  void _edit(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RegisterVehicleScreen(existing: vehicle)));
  }

  void _viewPhoto(BuildContext context, String path) {
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
            child: Image.file(File(path)),
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final vt = VehicleType.fromLabel(vehicle.vehicleType);
    final zone = kZones.firstWhere((z) => z.id == vehicle.defaultZoneId,
        orElse: () => kZones.first);
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Vehicle details',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Edit',
            onPressed: () => _edit(context),
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
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
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18,
                                    letterSpacing: 1.2)),
                            Text(
                                'registered ${DateFormat('MMM d, y').format(vehicle.registeredAt)}',
                                style: const TextStyle(
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
                      _DetailRow(label: 'Full name', value: vehicle.driverName),
                      const Divider(height: 20),
                      _DetailRow(label: 'Vehicle type', value: vt.label),
                      const Divider(height: 20),
                      _DetailRow(label: 'Default zone', value: zone.name),
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
                      const Text('Documents',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _DocPhoto(
                              label: "Driver's license",
                              path: vehicle.driverLicensePhotoPath,
                              onTap: vehicle.driverLicensePhotoPath == null
                                  ? null
                                  : () => _viewPhoto(context,
                                      vehicle.driverLicensePhotoPath!),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _DocPhoto(
                              label: 'OR/CR',
                              path: vehicle.orCrPhotoPath,
                              onTap: vehicle.orCrPhotoPath == null
                                  ? null
                                  : () => _viewPhoto(
                                      context, vehicle.orCrPhotoPath!),
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
                label: 'Edit vehicle',
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
              style: const TextStyle(
                  color: YosColors.sub,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(value.isEmpty ? '—' : value,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

/// Document photo tile — the captured image itself (tap to zoom) or a
/// plain "Not captured" placeholder if that document was never scanned.
class _DocPhoto extends StatelessWidget {
  const _DocPhoto({required this.label, required this.path, this.onTap});
  final String label;
  final String? path;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
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
              child: path != null
                  ? Image.file(File(path!), fit: BoxFit.cover)
                  : Container(
                      color: YosColors.surfaceHigh,
                      alignment: Alignment.center,
                      child: const Text('Not captured',
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
