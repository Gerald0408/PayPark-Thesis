import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../services/document_ocr.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/toast.dart';
import 'document_scan_screen.dart';

/// What [VehicleAttachmentScreen] hands back on Confirm.
class VehicleAttachmentResult {
  const VehicleAttachmentResult({
    required this.driverName,
    required this.plateNumber,
    required this.vehicleType,
    required this.licensePhotoPath,
    required this.orCrPhotoPath,
  });

  final String driverName;
  final String plateNumber;

  /// Null means the OR/CR scan never read a recognizable type (or nothing
  /// was scanned) — the caller should leave whatever type it already had
  /// selected rather than reset it.
  final VehicleType? vehicleType;
  final String? licensePhotoPath;
  final String? orCrPhotoPath;
}

/// Dedicated "attach documents" step: capture the driver's license and
/// OR/CR, review the name and plate number DocumentOcr read off them (or
/// type them by hand), then Confirm. Pulled out of RegisterVehicleScreen's
/// long scrolling form into its own focused screen — reached via the
/// Attachment button there — so capturing documents and registering the
/// rest of the vehicle's details (type, zone, RFID) don't compete for
/// attention on one page.
class VehicleAttachmentScreen extends StatefulWidget {
  const VehicleAttachmentScreen({
    super.key,
    this.initialDriverName = '',
    this.initialPlateNumber = '',
    this.initialLicensePhotoPath,
    this.initialOrCrPhotoPath,
  });

  final String initialDriverName;
  final String initialPlateNumber;
  final String? initialLicensePhotoPath;
  final String? initialOrCrPhotoPath;

  @override
  State<VehicleAttachmentScreen> createState() =>
      _VehicleAttachmentScreenState();
}

class _VehicleAttachmentScreenState extends State<VehicleAttachmentScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _driver;
  late final TextEditingController _plate;
  String? _licensePhotoPath;
  String? _orCrPhotoPath;
  VehicleType? _detectedType;

  @override
  void initState() {
    super.initState();
    _driver = TextEditingController(text: widget.initialDriverName);
    _plate = TextEditingController(text: widget.initialPlateNumber);
    _licensePhotoPath = widget.initialLicensePhotoPath;
    _orCrPhotoPath = widget.initialOrCrPhotoPath;
  }

  @override
  void dispose() {
    _driver.dispose();
    _plate.dispose();
    super.dispose();
  }

  /// Opens the camera+OCR capture flow for either document slot and uses
  /// DocumentOcr's best-effort parse to pre-fill whichever of driver name
  /// / plate / vehicle type it could read. That parse is a guess, not a
  /// guarantee — small print and non-standard layouts routinely confuse
  /// it — so every field it touches stays editable (see the TextFormFields
  /// below), and "View" always lets the collector check the auto-fill
  /// against the actual captured document rather than a reconstructed
  /// text guess, which catches everything a parser could miss (signatures,
  /// photos, anything OCR just can't read).
  Future<void> _scanDocument({required bool isLicense}) async {
    final result = await Navigator.of(context).push<DocumentScanResult>(
      MaterialPageRoute(
        builder: (_) => DocumentScanScreen(
          title: isLicense ? "Scan driver's license" : 'Scan OR/CR',
          instructions: isLicense
              ? 'Align the license within the frame, then Capture'
              : 'Align the OR/CR within the frame, then Capture',
        ),
      ),
    );
    if (result == null || !mounted) return;

    final oldPath = isLicense ? _licensePhotoPath : _orCrPhotoPath;
    if (oldPath != null) {
      final f = File(oldPath);
      if (await f.exists()) unawaited(f.delete());
    }

    final read = <String>[];
    if (isLicense) {
      final parsed = DocumentOcr.parseDriverLicense(result.rawText);
      if (parsed.name != null) {
        _driver.text = parsed.name!;
        read.add(parsed.name!);
      }
      if (parsed.licenseNumber != null) {
        read.add('License ${parsed.licenseNumber}');
      }
    } else {
      final parsed = DocumentOcr.parseOrCr(result.rawText);
      if (parsed.plate != null) {
        _plate.text = parsed.plate!;
        read.add('Plate ${parsed.plate}');
      }
      // Owner name is a fallback for driver name only — a driver's
      // license read (if one's been scanned) is the more authoritative
      // source for who's actually driving, vs. who owns the vehicle.
      if (parsed.ownerName != null && _driver.text.trim().isEmpty) {
        _driver.text = parsed.ownerName!;
        read.add(parsed.ownerName!);
      }
      if (parsed.vehicleTypeLabel != null) {
        final match = VehicleType.values
            .where((t) => t.label == parsed.vehicleTypeLabel);
        if (match.isNotEmpty) {
          _detectedType = match.first;
          read.add(_detectedType!.label);
        }
      }
    }

    if (!mounted) return;
    setState(() {
      if (isLicense) {
        _licensePhotoPath = result.imagePath;
      } else {
        _orCrPhotoPath = result.imagePath;
      }
    });
    Toast.info(
        context,
        read.isNotEmpty
            ? 'Read: ${read.join(' · ')}'
            : "Photo saved, but couldn't read the details — check "
                '"View" or try rescanning with better lighting.');
  }

  /// Full-screen, pinch-to-zoom view of a captured document photo — lets
  /// the collector double-check (or catch a bad auto-fill) against the
  /// real image instead of a reconstructed OCR text guess (see
  /// _scanDocument's doc comment).
  void _viewPhoto(String path) {
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

  void _confirm() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(VehicleAttachmentResult(
      driverName: _driver.text.trim(),
      plateNumber: _plate.text.trim(),
      vehicleType: _detectedType,
      licensePhotoPath: _licensePhotoPath,
      orCrPhotoPath: _orCrPhotoPath,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Attachment',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                PopIn(
                  child: GlassCard(
                    child: _DocCaptureCard(
                      label: "Driver's license",
                      photoPath: _licensePhotoPath,
                      onScan: () => _scanDocument(isLicense: true),
                      onViewPhoto: _licensePhotoPath == null
                          ? null
                          : () => _viewPhoto(_licensePhotoPath!),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                PopIn(
                  delayMs: 60,
                  child: GlassCard(
                    child: _DocCaptureCard(
                      label: 'OR/CR',
                      photoPath: _orCrPhotoPath,
                      onScan: () => _scanDocument(isLicense: false),
                      onViewPhoto: _orCrPhotoPath == null
                          ? null
                          : () => _viewPhoto(_orCrPhotoPath!),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                PopIn(
                  delayMs: 120,
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Please update the details below if '
                            'there\'s any change.',
                            style: TextStyle(
                                color: YosColors.warn,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _driver,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                            hintText:
                                'Filled from license scan — edit if needed',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          validator: (v) => (v == null || v.trim().length < 2)
                              ? 'Scan the driver\'s license or type the name'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _plate,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'Plate number',
                            hintText:
                                'Filled from OR/CR scan — edit if needed',
                            prefixIcon: Icon(Icons.pin_outlined),
                          ),
                          validator: (v) => (v == null || v.trim().length < 5)
                              ? 'Scan the OR/CR or type the plate number'
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                BreathingGlowButton(
                  label: 'Confirm',
                  icon: Icons.check_rounded,
                  onPressed: _confirm,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One document's capture card — photo preview (or placeholder) on top,
/// View + Capture/Retake side by side below.
class _DocCaptureCard extends StatelessWidget {
  const _DocCaptureCard({
    required this.label,
    required this.photoPath,
    required this.onScan,
    this.onViewPhoto,
  });

  final String label;
  final String? photoPath;
  final VoidCallback onScan;
  final VoidCallback? onViewPhoto;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoPath != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 1.7,
            child: hasPhoto
                ? Image.file(File(photoPath!), fit: BoxFit.cover)
                : Container(
                    color: YosColors.surfaceHigh,
                    alignment: Alignment.center,
                    child: const Icon(Icons.badge_outlined,
                        color: YosColors.sub, size: 32),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onViewPhoto,
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('View'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: Text(hasPhoto ? 'Retake' : 'Capture'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
