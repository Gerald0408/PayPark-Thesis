import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../core/theme.dart';
import '../services/locale_controller.dart';

/// Reconstructs recognized text in genuine top-to-bottom, left-to-right
/// reading order using each line's actual position on the page, instead
/// of trusting RecognizedText.text's own block order. ML Kit groups text
/// into blocks by visual proximity, not by row — on a two-column layout
/// like a PH driver's license (a label and its value sitting side by
/// side, or two unrelated fields sharing a horizontal band), that block
/// order routinely interleaves lines that have nothing to do with each
/// other, which is what "the text isn't aligned" was actually seeing.
///
/// Every recognized line is flattened, sorted by vertical position, then
/// grouped into rows with any other line whose vertical center falls
/// within about 60% of a line-height of the current row — narrow enough
/// that a genuinely new row (the next label down) still starts a new
/// line, wide enough to tolerate the slight vertical jitter between two
/// lines that are really on the same printed row. Each row is then
/// sorted left-to-right before being joined, so a label and its value
/// come out in the right order even when ML Kit read them as separate
/// blocks.
String _readingOrderText(RecognizedText recognized) {
  final lines = <TextLine>[
    for (final block in recognized.blocks) ...block.lines,
  ];
  if (lines.isEmpty) return recognized.text;
  lines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

  final rows = <List<TextLine>>[];
  for (final line in lines) {
    final lineMid = (line.boundingBox.top + line.boundingBox.bottom) / 2;
    if (rows.isNotEmpty) {
      final lastRow = rows.last;
      final rowMid = lastRow
              .map((l) => (l.boundingBox.top + l.boundingBox.bottom) / 2)
              .reduce((a, b) => a + b) /
          lastRow.length;
      final rowHeight =
          lastRow.map((l) => l.boundingBox.height).reduce((a, b) => a + b) /
              lastRow.length;
      if ((lineMid - rowMid).abs() < rowHeight * 0.6) {
        lastRow.add(line);
        continue;
      }
    }
    rows.add([line]);
  }

  final buffer = StringBuffer();
  for (final row in rows) {
    row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
    buffer.writeln(row.map((l) => l.text).join('   '));
  }
  return buffer.toString().trim();
}

class DocumentScanResult {
  const DocumentScanResult({required this.imagePath, required this.rawText});

  /// Permanent local path (app documents dir) — safe to persist and
  /// reference later, unlike the camera plugin's own temp file.
  final String imagePath;
  final String rawText;
}

/// Generic "photograph a document, run OCR over it" capture screen — used
/// for both the driver's license and the OR/CR. The caller decides what to
/// do with the recognized text; this screen only owns the camera, the
/// confirm/retake step, and saving the photo somewhere durable.
class DocumentScanScreen extends StatefulWidget {
  const DocumentScanScreen({
    super.key,
    required this.title,
    required this.instructions,
    this.portrait = false,
  });

  final String title;
  final String instructions;

  /// Shapes the guide frame (and so the cropped photo) taller-than-wide
  /// instead of the default wider-than-tall — an OR/CR is a tall slip,
  /// unlike the landscape card a driver's license is (see
  /// VehicleAttachmentScreen._scanDocument, the only caller).
  final bool portrait;

  @override
  State<DocumentScanScreen> createState() => _DocumentScanScreenState();
}

class _DocumentScanScreenState extends State<DocumentScanScreen> {
  CameraController? _cam;
  TextRecognizer? _tr;

  bool _initializing = true;
  bool _busy = false;
  String? _error;
  String? _shotPath; // camera plugin's temp file, pre-confirm

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// Same rect the on-screen guide border is drawn at in [build] — kept as
  /// one source of truth so the crop in [_cropToFrame] always grabs exactly
  /// what the guide visually promises, never more of the background (e.g.
  /// the table the license is sitting on).
  ///
  /// Both orientations share one long-side length, derived from the same
  /// fraction of the screen's shortest side, and the same 320:200 (1.6:1)
  /// aspect ratio — just swapped for [portrait] — rather than two
  /// independently tuned sizes. That's what keeps the OR/CR frame and the
  /// license frame reading as a matched pair of capture targets instead of
  /// two differently-scaled boxes, while still shrinking to fit a narrow
  /// or short phone either way.
  Rect _frameRect(Size screen) {
    final shortestSide = math.min(screen.width, screen.height);
    final long = math.min(360.0, shortestSide * 0.86);
    final short = long * (200 / 320);
    final w = widget.portrait ? short : long;
    final h = widget.portrait ? long : short;
    return Rect.fromCenter(
        center: Offset(screen.width / 2, screen.height / 2),
        width: w,
        height: h);
  }

  /// Crops the raw capture down to just the guide-frame region so the saved
  /// document photo is the license/OR-CR itself, not whatever surface it
  /// was sitting on. Returns null (caller keeps the uncropped shot) if
  /// anything about the image can't be read — better to save the full
  /// photo than fail the capture outright.
  Future<String?> _cropToFrame(String path) async {
    if (!mounted) return null;
    final screen = MediaQuery.of(context).size;
    final frame = _frameRect(screen);
    try {
      final bytes = await File(path).readAsBytes();
      var decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      // Camera captures commonly carry EXIF rotation instead of rotating
      // the pixel buffer itself — bake it in first so the crop fractions
      // (measured against the upright on-screen preview) land on the same
      // upright image instead of a still-sideways one.
      decoded = img.bakeOrientation(decoded);

      // The preview fills the whole screen (Stack.expand, no letterboxing
      // or aspect correction), so a fraction of screen width/height maps
      // directly onto the same fraction of the captured image, per axis.
      final fx = frame.left / screen.width;
      final fy = frame.top / screen.height;
      final fw = frame.width / screen.width;
      final fh = frame.height / screen.height;

      final x = (decoded.width * fx).round().clamp(0, decoded.width - 1);
      final y = (decoded.height * fy).round().clamp(0, decoded.height - 1);
      final w = (decoded.width * fw).round().clamp(1, decoded.width - x);
      final h = (decoded.height * fh).round().clamp(1, decoded.height - y);

      final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      await File(path).writeAsBytes(img.encodeJpg(cropped, quality: 92));
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _init() async {
    if (kIsWeb) {
      setState(() {
        _initializing = false;
        _error = t('Document scanning is only available on the Android app.',
            'Available lang ang pag-scan ng dokumento sa Android app.');
      });
      return;
    }
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = status.isPermanentlyDenied
            ? t(
                'Camera blocked. Settings > Apps > PayPark > Permissions > Camera',
                'Naka-block ang camera. Settings > Apps > PayPark > Permissions > Camera')
            : t('Camera permission denied.', 'Tinanggihan ang pahintulot sa camera.');
      });
      return;
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() {
          _initializing = false;
          _error = t('No camera found.', 'Walang nakitang camera.');
        });
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      _cam =
          CameraController(back, ResolutionPreset.veryHigh, enableAudio: false);
      await _cam!.initialize();
      _tr = TextRecognizer(script: TextRecognitionScript.latin);
      if (mounted) setState(() => _initializing = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = t('Camera error: $e', 'Error sa camera: $e');
        });
      }
    }
  }

  Future<void> _capture() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      try {
        await cam.setFocusMode(FocusMode.auto);
        await cam.setFocusPoint(const Offset(0.5, 0.5));
        await cam.setExposureMode(ExposureMode.auto);
        await cam.setExposurePoint(const Offset(0.5, 0.5));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
      final shot = await cam.takePicture();
      final cropped = await _cropToFrame(shot.path);
      if (!mounted) return;
      setState(() => _shotPath = cropped ?? shot.path);
    } catch (e) {
      if (mounted) {
        setState(() => _error = t('Capture failed: $e', 'Hindi nakuha: $e'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final path = _shotPath;
    final tr = _tr;
    if (path == null || tr == null || _busy) return;
    setState(() => _busy = true);
    try {
      final recognized = await tr.processImage(InputImage.fromFilePath(path));
      final dir = await getApplicationDocumentsDirectory();
      final docsDir = Directory('${dir.path}/vehicle_docs');
      if (!await docsDir.exists()) await docsDir.create(recursive: true);
      final savedPath = '${docsDir.path}/${const Uuid().v4()}.jpg';
      await File(path).copy(savedPath);
      if (!mounted) return;
      Navigator.of(context).pop(
        DocumentScanResult(
            imagePath: savedPath, rawText: _readingOrderText(recognized)),
      );
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = t('Couldn\'t process photo: $e', 'Hindi ma-process ang litrato: $e'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _cam?.dispose();
    _tr?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _cam?.value.isInitialized == true;
    final hasShot = _shotPath != null;
    return Scaffold(
      backgroundColor: YosColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (hasShot)
            // contain, not cover — this is the already-cropped, document-
            // shaped photo (see _cropToFrame), and its aspect ratio has no
            // reason to match the phone screen's. cover would zoom to fill
            // the screen and clip the edges of what was actually captured;
            // contain shows the whole thing, letterboxed if need be.
            Container(
              color: Colors.black,
              child: Image.file(File(_shotPath!), fit: BoxFit.contain),
            )
          else if (ready)
            // Deliberately still the plain stretched CameraPreview, not
            // CoverCameraPreview — _cropToFrame below maps the on-screen
            // guide frame to the captured image using direct
            // screen-fraction coordinates, which only lines up because
            // this preview stretches 1:1 to the screen with no aspect
            // correction. Switching this to a "cover" crop would shift
            // what that math actually grabs out of the saved photo.
            CameraPreview(_cam!)
          else if (_initializing)
            Center(child: CircularProgressIndicator(color: YosColors.accent))
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_error ?? t('Camera unavailable.', 'Hindi available ang camera.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: YosColors.ink, fontSize: 15)),
              ),
            ),
          if (ready && !hasShot)
            Builder(builder: (context) {
              final frame = _frameRect(MediaQuery.of(context).size);
              return IgnorePointer(
                child: Center(
                  child: Container(
                    width: frame.width,
                    height: frame.height,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 3),
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              );
            }),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x66000000), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon:
                          const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                    Expanded(
                      child: Text(widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hasShot
                            ? t('Use this photo?', 'Gamitin ang litratong ito?')
                            : widget.instructions,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: YosColors.sub,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.0),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: YosColors.bad,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ],
                      const SizedBox(height: 16),
                      if (!hasShot)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: (!ready || _busy) ? null : _capture,
                            style: FilledButton.styleFrom(
                              // YosColors.accentDeep/onAccent — the same
                              // amber-in-light/yellow-in-dark pairing every
                              // other primary capture CTA in the app uses
                              // (Scan Face ID, Save Face ID/Retake), so this
                              // button actually tracks the mode toggle
                              // instead of staying a fixed near-black in
                              // both.
                              backgroundColor: YosColors.accentDeep,
                              foregroundColor: YosColors.onAccent,
                              disabledBackgroundColor:
                                  YosColors.accentDeep.withValues(alpha: 0.5),
                              disabledForegroundColor:
                                  YosColors.onAccent.withValues(alpha: 0.75),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999)),
                            ),
                            icon: _busy
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: YosColors.onAccent
                                            .withValues(alpha: 0.75)),
                                  )
                                : const Icon(Icons.camera_alt_rounded),
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                  _busy
                                      ? t('Working...', 'Ginagawa...')
                                      : t('Capture', 'Kumuha'),
                                  maxLines: 1,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                            ),
                          ),
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _busy
                                    ? null
                                    : () => setState(() => _shotPath = null),
                                style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(999)),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(t('Retake', 'Kunin Ulit'),
                                      maxLines: 1,
                                      style: TextStyle(
                                          color: YosColors.ink,
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                onPressed: _busy ? null : _confirm,
                                style: FilledButton.styleFrom(
                                  backgroundColor: YosColors.good,
                                  foregroundColor: YosColors.ink,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(999)),
                                ),
                                child: _busy
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: YosColors.ink),
                                      )
                                    : FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                            t('Use this photo', 'Gamitin ang Litratong Ito'),
                                            maxLines: 1,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w800)),
                                      ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
