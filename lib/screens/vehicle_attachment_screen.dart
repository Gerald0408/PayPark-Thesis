import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../services/document_ocr.dart';
import '../services/locale_controller.dart';
import '../services/ocr_reading_order.dart';
import '../services/plate_matcher.dart';
import '../services/vehicle_document_cache.dart';
import '../widgets/doc_photo_view.dart';
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
    required this.licensePhotoUrl,
    required this.orCrPhotoUrl,
  });

  final String driverName;
  final String plateNumber;

  /// Null means the OR/CR scan never read a recognizable type (or nothing
  /// was scanned) — the caller should leave whatever type it already had
  /// selected rather than reset it.
  final VehicleType? vehicleType;
  final String? licensePhotoPath;
  final String? orCrPhotoPath;

  /// Whichever synced Storage URL each photo already had (see
  /// RegisterVehicleScreen/VehicleRegistry.register) — null whenever the
  /// matching path above was just (re)captured on this screen, since a
  /// fresh local capture hasn't been uploaded yet.
  final String? licensePhotoUrl;
  final String? orCrPhotoUrl;
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
    this.initialLicensePhotoUrl,
    this.initialOrCrPhotoUrl,
  });

  final String initialDriverName;
  final String initialPlateNumber;
  final String? initialLicensePhotoPath;
  final String? initialOrCrPhotoPath;
  final String? initialLicensePhotoUrl;
  final String? initialOrCrPhotoUrl;

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
  String? _licensePhotoUrl;
  String? _orCrPhotoUrl;
  VehicleType? _detectedType;

  @override
  void initState() {
    super.initState();
    _driver = TextEditingController(text: widget.initialDriverName);
    _plate = TextEditingController(text: widget.initialPlateNumber);
    _licensePhotoPath = widget.initialLicensePhotoPath;
    _orCrPhotoPath = widget.initialOrCrPhotoPath;
    _licensePhotoUrl = widget.initialLicensePhotoUrl;
    _orCrPhotoUrl = widget.initialOrCrPhotoUrl;
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
          title: isLicense
              ? t("Scan driver's license", "I-scan ang Driver's License")
              : t('Scan OR/CR', 'I-scan ang OR/CR'),
          instructions: isLicense
              ? t('Align the license within the frame, then Capture',
                  'Ihanay ang license sa loob ng frame, tapos Capture')
              : t('Align the OR/CR within the frame, then Capture',
                  'Ihanay ang OR/CR sa loob ng frame, tapos Capture'),
          portrait: !isLicense,
        ),
      ),
    );
    if (result == null || !mounted) return;
    _applyDocumentResult(
        isLicense: isLicense, filePath: result.filePath, rawText: result.rawText);
  }

  /// Lets the collector pick an existing photo from the device's own
  /// gallery instead of using the camera — a document photo someone
  /// already sent them, or one taken earlier outside this app. Runs the
  /// same OCR auto-fill as [_scanDocument]; the picked photo isn't
  /// cropped to a guide frame the way a fresh capture is (there's no
  /// camera preview to align against here), so whatever the collector
  /// picked is used as-is.
  Future<void> _importImage({required bool isLicense}) async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (picked == null || !mounted) return;
    try {
      final tr = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognized;
      try {
        recognized = await tr.processImage(InputImage.fromFilePath(picked.path));
      } finally {
        await tr.close();
      }
      final key = '${const Uuid().v4()}.jpg';
      await VehicleDocumentCache.instance
          .write(key, await File(picked.path).readAsBytes());
      if (!mounted) return;
      _applyDocumentResult(
          isLicense: isLicense,
          filePath: key,
          rawText: OcrReadingOrder.reconstruct(recognized));
    } catch (e) {
      if (mounted) {
        Toast.error(context,
            t("Couldn't import photo: $e", 'Hindi na-import ang litrato: $e'));
      }
    }
  }

  /// Shared tail for both [_scanDocument] and [_importImage]: runs
  /// DocumentOcr's best-effort parse over whichever photo just came in
  /// and pre-fills whichever of driver name / plate / vehicle type it
  /// could read. That parse is a guess, not a guarantee — small print and
  /// non-standard layouts routinely confuse it — so every field it
  /// touches stays editable (see the TextFormFields below), and "View"
  /// always lets the collector check the auto-fill against the actual
  /// document rather than a reconstructed text guess, which catches
  /// everything a parser could miss (signatures, photos, anything OCR
  /// just can't read).
  void _applyDocumentResult({
    required bool isLicense,
    required String filePath,
    required String rawText,
  }) {
    // The old local file is deliberately left on disk here rather than
    // deleted — this screen's Confirm hasn't run yet, let alone the
    // caller's own save. Deleting it eagerly used to mean backing out
    // after a retake (system back, cancelling the parent form, the app
    // getting killed) silently destroyed the previous photo with no way
    // back, since it might never have finished syncing to Storage yet.
    // A harmless orphaned file is a far cheaper mistake than losing a
    // vehicle's captured document.
    final read = <String>[];
    if (isLicense) {
      final parsed = DocumentOcr.parseDriverLicense(rawText);
      if (parsed.name != null) {
        _driver.text = parsed.name!;
        read.add(parsed.name!);
      }
      if (parsed.licenseNumber != null) {
        read.add('License ${parsed.licenseNumber}');
      }
    } else {
      final parsed = DocumentOcr.parseOrCr(rawText);
      if (parsed.plate != null) {
        _plate.text = parsed.plate!;
        read.add('Plate ${parsed.plate}');
      }
      // Full name only ever comes from the driver's license scan, never
      // from here — the OR/CR's registered owner isn't necessarily who's
      // actually driving, so it's never a valid stand-in for that field.
      if (parsed.vehicleTypeLabel != null) {
        final match =
            VehicleType.values.where((t) => t.label == parsed.vehicleTypeLabel);
        if (match.isNotEmpty) {
          _detectedType = match.first;
          read.add(_detectedType!.label);
        }
      }
    }

    setState(() {
      if (isLicense) {
        _licensePhotoPath = filePath;
        // A fresh capture replaces the image entirely — any URL already
        // synced for the old photo no longer matches, so it's cleared
        // rather than kept, which is what tells register() to actually
        // upload this new one (see its own doc comment).
        _licensePhotoUrl = null;
      } else {
        _orCrPhotoPath = filePath;
        _orCrPhotoUrl = null;
      }
    });
    Toast.info(
        context,
        read.isNotEmpty
            ? t('Read: ${read.join(' · ')}', 'Nabasa: ${read.join(' · ')}')
            : t(
                "Photo saved, but couldn't read the details — check "
                    '"View" or try rescanning with better lighting.',
                'Na-save ang larawan, pero hindi mabasa ang mga detalye — '
                    'tingnan ang "View" o subukang i-scan ulit sa mas '
                    'maliwanag na lugar.'));
  }

  /// Camera+OCR shortcut for the plate field itself, separate from
  /// [_scanDocument]'s OR/CR capture — that one only reads a plate when
  /// it happens to appear somewhere on the OR/CR slip; this one photographs
  /// the plate directly (landscape framing, like the license) and matches
  /// the recognized text against [PlateMatcher]'s own PH-plate shapes, the
  /// same matcher DocumentOcr.parseOrCr already trusts. The photo itself
  /// isn't kept — there's no "plate photo" field on the vehicle, just the
  /// plate number text — so it's deleted right after OCR runs over it.
  Future<void> _scanPlate() async {
    final result = await Navigator.of(context).push<DocumentScanResult>(
      MaterialPageRoute(
        builder: (_) => DocumentScanScreen(
          title: t('Scan plate number', 'I-scan ang Plaka Numero'),
          instructions: t('Align the plate within the frame, then Capture',
              'Ihanay ang plaka sa loob ng frame, tapos Capture'),
        ),
      ),
    );
    if (result == null) return;
    unawaited(File(result.filePath).delete());
    if (!mounted) return;
    final plate = PlateMatcher.bestMatch(PlateMatcher.clean(result.rawText));
    if (plate == null) {
      Toast.warn(
          context,
          t("Couldn't read a plate number — try again or type it in.",
              'Hindi mabasa ang plaka numero — subukan ulit o i-type na lang.'));
      return;
    }
    setState(() => _plate.text = plate);
    Toast.info(context, t('Plate read: $plate', 'Nabasang plaka: $plate'));
  }

  /// Full-screen, pinch-to-zoom view of a captured document photo — lets
  /// the collector double-check (or catch a bad auto-fill) against the
  /// real image instead of a reconstructed OCR text guess (see
  /// _scanDocument's doc comment).
  void _viewPhoto(String? path, String? url) {
    final view = DocPhotoView(path: path, url: url, fit: BoxFit.contain);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        // A PDF already provides its own pinch-to-zoom (see
        // DocPhotoView/PdfPreview) — wrapping it in another InteractiveViewer
        // would fight that one over the same gestures, so this only adds
        // one for the plain-image fallback case.
        body: Center(
          child: DocPhotoView.isPdfSource(path, url)
              ? view
              : InteractiveViewer(minScale: 0.5, maxScale: 4, child: view),
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
      licensePhotoUrl: _licensePhotoUrl,
      orCrPhotoUrl: _orCrPhotoUrl,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Attachment', 'Attachment'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
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
                      label: t("Driver's license", "Driver's License"),
                      photoPath: _licensePhotoPath,
                      photoUrl: _licensePhotoUrl,
                      onScan: () => _scanDocument(isLicense: true),
                      onImport: () => _importImage(isLicense: true),
                      onViewPhoto: (_licensePhotoPath ?? _licensePhotoUrl) ==
                              null
                          ? null
                          : () => _viewPhoto(_licensePhotoPath, _licensePhotoUrl),
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
                      photoUrl: _orCrPhotoUrl,
                      onScan: () => _scanDocument(isLicense: false),
                      onImport: () => _importImage(isLicense: false),
                      onViewPhoto: (_orCrPhotoPath ?? _orCrPhotoUrl) == null
                          ? null
                          : () => _viewPhoto(_orCrPhotoPath, _orCrPhotoUrl),
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
                        Text(
                            t(
                                'Please update the details below if '
                                    "there's any change.",
                                'Paki-update ang mga detalye sa ibaba kung '
                                    'may pagbabago.'),
                            style: TextStyle(
                                color: YosColors.warn,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _driver,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            labelText: t('Full name', 'Buong Pangalan'),
                            hintText: t(
                                'Filled from license scan — edit if needed',
                                'Napunan mula sa license scan — i-edit kung kailangan'),
                            prefixIcon: const Icon(Icons.badge_outlined),
                          ),
                          validator: (v) => (v == null || v.trim().length < 2)
                              ? t("Scan the driver's license or type the name",
                                  "I-scan ang driver's license o i-type ang pangalan")
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _plate,
                          textCapitalization: TextCapitalization.characters,
                          decoration: InputDecoration(
                            labelText: t('Plate number', 'Plaka Numero'),
                            hintText: t('Scan the plate, OR/CR, or type it in',
                                'I-scan ang plaka, OR/CR, o i-type ito'),
                            prefixIcon: const Icon(Icons.pin_outlined),
                            suffixIcon: IconButton(
                              tooltip: t('Scan plate number', 'I-scan ang Plaka Numero'),
                              icon: const Icon(Icons.camera_alt_outlined),
                              onPressed: _scanPlate,
                            ),
                          ),
                          validator: (v) => (v == null || v.trim().length < 5)
                              ? t(
                                  'Scan the plate/OR-CR or type the plate number',
                                  'I-scan ang plaka/OR-CR o i-type ang plaka numero')
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                BreathingGlowButton(
                  label: t('Confirm', 'Kumpirmahin'),
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
/// View / Capture-Retake / Import from a row below. View and Import stay
/// compact icon-only buttons rather than full labeled ones so the row
/// still fits three actions on a narrow phone without wrapping or
/// overflowing — Capture/Retake is the one action that actually needs a
/// label, being the primary action on this card.
class _DocCaptureCard extends StatelessWidget {
  const _DocCaptureCard({
    required this.label,
    required this.photoPath,
    required this.photoUrl,
    required this.onScan,
    required this.onImport,
    this.onViewPhoto,
  });

  final String label;
  final String? photoPath;
  final String? photoUrl;
  final VoidCallback onScan;

  /// Opens the device's own gallery to pick an existing photo instead of
  /// using the camera — see VehicleAttachmentScreen._importImage.
  final VoidCallback onImport;
  final VoidCallback? onViewPhoto;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoPath != null || photoUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: YosColors.ink,
                fontWeight: FontWeight.w800,
                fontSize: 15)),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 1.7,
            child: hasPhoto
                ? DocPhotoView(path: photoPath, url: photoUrl)
                : Container(
                    color: YosColors.surfaceHigh,
                    alignment: Alignment.center,
                    child: Icon(Icons.badge_outlined,
                        color: YosColors.sub, size: 32),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            IconButton.outlined(
              onPressed: onViewPhoto,
              tooltip: t('View', 'Tingnan'),
              icon: const Icon(Icons.visibility_outlined, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                // FittedBox: a longer translated label ("Kunin Ulit") had
                // nothing stopping it from overflowing this narrow,
                // icon-sharing button — see BreathingGlowButton's matching
                // fix for the same underlying issue.
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                      hasPhoto
                          ? t('Retake', 'Kunin Ulit')
                          : t('Capture', 'Kumuha'),
                      maxLines: 1),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.outlined(
              onPressed: onImport,
              tooltip: t('Import from device', 'I-import mula sa device'),
              icon: const Icon(Icons.photo_library_outlined, size: 20),
            ),
          ],
        ),
      ],
    );
  }
}
