import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/face_auth_service.dart';
import '../services/face_embedding_service.dart';
import '../services/face_geometry.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/scanner_frame.dart';
import '../widgets/toast.dart';
import 'intro_screen.dart';

/// Captures a face and enrolls it for face sign-in on this device — a
/// mandatory step (see YosRepository.markFaceIdEnrolled / hasFaceId in
/// firestore.rules) reached right after registration, right after a login
/// that hasn't enrolled yet, or forced by RootShell's route guard on any
/// other path into the dashboard. The caller decides what happens next via
/// [onFinished], which only ever fires once a capture is actually saved —
/// there's no skipping this anymore.
class FaceEnrollScreen extends StatefulWidget {
  const FaceEnrollScreen({
    super.key,
    required this.uid,
    required this.name,
    required this.email,
    required this.password,
    required this.onFinished,
  });

  final String uid;
  final String name;
  final String email;
  final String password;

  /// Receives this screen's own (still-mounted) [BuildContext] — callers
  /// must use it for any navigation here, not a context captured from
  /// wherever this screen was built. Register screen builds this via
  /// `pushReplacement`, which disposes its own State as soon as that
  /// transition finishes, well before the collector finishes capturing;
  /// navigating with the outer context after that throws "this widget has
  /// been unmounted."
  final void Function(BuildContext context) onFinished;

  @override
  State<FaceEnrollScreen> createState() => _FaceEnrollScreenState();
}

class _FaceEnrollScreenState extends State<FaceEnrollScreen> {
  CameraController? _cam;
  FaceDetector? _fd;

  bool _initializing = true;
  bool _capturing = false;
  bool _saving = false;
  String? _error;
  List<double>? _captured;
  double _progress = 0;

  // Shown right above the face circle, live, throughout the scan — a
  // single frontal capture only now (no more blink/turn-left/turn-right
  // follow-up phases, which is what used to make enrollment take so
  // long: three extra scans, each with its own pose to hold).
  String get _instruction => t('Look straight into the camera and hold still',
      'Tumingin nang diretso sa camera at huwag gumalaw');

  // Good frames needed before capture is done — every frame that passes
  // FaceGeometry.qualityIssue's strict gate gets averaged together (see
  // FaceEmbeddingService.average) into the stored template. There's no
  // attempt cap: a frame that doesn't pass just updates [_error] live and
  // the loop keeps shooting on its own (see _capture) rather than bailing
  // out to a dead "Capture" button the user has to tap again — the whole
  // point of a guided scan is that it corrects itself as the user follows
  // the on-screen feedback, not that it gives up.
  static const _targetFrames = 3;

  // Delay between shots — just enough for the camera/ML Kit pipeline to
  // free up between frames, not a deliberate slow-down.
  static const _shotDelay = Duration(milliseconds: 45);

  @override
  void initState() {
    super.initState();
    // Camera/ML Kit init (and the camera-permission prompt that comes
    // with it) now fires the instant this screen opens — no more "Get
    // Started" splash to tap through first.
    _init();
  }

  Future<void> _init() async {
    if (kIsWeb) {
      setState(() {
        _initializing = false;
        _error = t('Face capture is only available on the Android app.',
            'Available lang ang face capture sa Android app.');
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
    // camera_android_camerax has a known race right after a *runtime*
    // permission grant: its ProcessCameraProvider isn't bound to the
    // Activity yet, so the very next initialize() throws a raw "Null
    // check operator used on a null value" from inside the plugin
    // itself, not this app's code — most visible right here, the first
    // time the app ever asks for the camera (e.g. Face ID straight after
    // registering, before anything else has touched the camera). One
    // short settle-and-retry clears it; a real failure (no camera,
    // hardware busy, etc.) still surfaces normally on the retry.
    for (var attempt = 0;; attempt++) {
      try {
        final cams = await availableCameras();
        if (cams.isEmpty) {
          if (mounted) {
            setState(() {
              _initializing = false;
              _error = t('No camera found.', 'Walang nahanap na camera.');
            });
          }
          return;
        }
        final front = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
          orElse: () => cams.first,
        );
        _cam = CameraController(front, ResolutionPreset.medium,
            enableAudio: false);
        await _cam!.initialize();
        // initialize() can report success while CameraX still hasn't
        // actually started pushing frames into the preview texture,
        // leaving it permanently black even though isInitialized is
        // true — resumePreview() is the plugin's own documented nudge
        // for exactly that stuck-black-frame state.
        await _cam!.resumePreview();
        _fd = FaceDetector(
          options: FaceDetectorOptions(
            enableClassification: true,
            enableLandmarks: true,
            performanceMode: FaceDetectorMode.accurate,
          ),
        );
        await FaceEmbeddingService.instance.loadModel();
        if (mounted) setState(() => _initializing = false);
        return;
      } catch (e) {
        await _cam?.dispose();
        _cam = null;
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 400));
          continue;
        }
        if (mounted) {
          setState(() {
            _initializing = false;
            _error = t('Camera error: $e', 'Error sa camera: $e');
          });
        }
        return;
      }
    }
  }

  /// One tap runs the whole burst-and-average loop — no attempt cap, no
  /// separate blink/turn-side follow-ups anymore: it keeps shooting
  /// frames, live-updating [_error] with whatever's wrong on each one
  /// (e.g. "Face the camera straight on"), until [_targetFrames] of them
  /// pass [FaceGeometry.qualityIssue]'s strict gate, then averages them
  /// into the stored template. Only stops early if the widget was
  /// disposed mid-scan (e.g. the user backed out).
  Future<void> _capture() async {
    final cam = _cam;
    final fd = _fd;
    if (cam == null || fd == null || !cam.value.isInitialized || _capturing) {
      return;
    }
    setState(() {
      _capturing = true;
      _error = null;
    });
    try {
      final vectors = <List<double>>[];
      while (vectors.length < _targetFrames) {
        if (!mounted) return;
        await Future.delayed(_shotDelay);
        final shot = await cam.takePicture();
        final faces =
            await fd.processImage(InputImage.fromFilePath(shot.path));
        String? issue;
        if (faces.isEmpty) {
          issue = t('No face found. Center your face in the frame.',
              'Walang nakitang mukha. I-center ang iyong mukha sa frame.');
        } else if (faces.length > 1) {
          issue = t('More than one face in frame.',
              'Higit sa isang mukha ang nasa frame.');
        } else {
          final face = faces.first;
          issue = FaceGeometry.qualityIssue(face, strict: true);
          if (issue == null) {
            final v = await FaceEmbeddingService.instance
                .extractEmbeddingFromFile(shot.path, face);
            if (v == null) {
              issue = t('Couldn\'t read your face clearly. Try again.',
                  'Hindi maliwanag nabasa ang iyong mukha. Subukan ulit.');
            } else {
              vectors.add(v);
            }
          }
        }
        if (mounted) {
          setState(() {
            _error = issue;
            _progress = vectors.length / _targetFrames;
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _error = null;
        _captured = FaceEmbeddingService.average(vectors);
      });
    } catch (e) {
      debugPrint('Face capture failed: $e');
      if (mounted) {
        setState(() => _error = t('Capture failed. Please try again.',
            'Nabigo ang pag-capture. Subukan ulit.'));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _save() async {
    final vector = _captured;
    if (vector == null || _saving) return;
    setState(() => _saving = true);
    try {
      await FaceAuthService.instance.enroll(
        uid: widget.uid,
        name: widget.name,
        email: widget.email,
        password: widget.password,
        embedding: vector,
      );
      // Marks the mandatory gate satisfied server-side (see
      // firestore.rules' hasFaceId()) — must happen only after a real
      // enrollment actually succeeds above, never speculatively.
      await YosRepository.instance.markFaceIdEnrolled();
      // Best-effort, same rule as the audit entry below: lets a
      // *different* phone recognize this same face later (see
      // FaceLoginScreen's cloud fallback) without ever blocking this
      // device's own enrollment on that network round-trip succeeding.
      try {
        await YosRepository.instance.syncFaceEmbedding(
          uid: widget.uid,
          name: widget.name,
          email: widget.email,
          embedding: vector,
        );
      } catch (_) {}
      // Best-effort only: an audit entry failing to write must never turn
      // an already-successful enrollment into a reported failure.
      try {
        await YosRepository.instance
            .logAudit(AuditAction.faceEnroll, 'Face ID Enrolled on Device');
      } catch (_) {}
      if (!mounted) return;
      Toast.success(context, t('Face ID saved', 'Na-save ang Face ID'));
      widget.onFinished(context);
    } catch (e) {
      // Same rule as everywhere else here: never surface a raw exception
      // (e.g. a transient Firestore permission-denied that outlasted
      // markFaceIdEnrolled's own retries) to the user.
      debugPrint('Face ID save failed: $e');
      if (mounted) {
        setState(() => _error = t('Couldn\'t save Face ID. Please try again.',
            'Hindi ma-save ang Face ID. Subukan ulit.'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _cam?.dispose();
    _fd?.close();
    super.dispose();
  }

  /// The close/back affordance needs to work whether this screen was
  /// pushed normally (register/login flows — just pop) or is standing in
  /// as RootShell's own build() output on a cold start with an already
  /// signed-in session (nothing to pop to at all). In the latter case the
  /// only sane way out of a mandatory step you can't complete right now is
  /// signing out entirely, not a dead button.
  Future<void> _closeOrSignOut() async {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    await YosRepository.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const IntroScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _cam?.value.isInitialized == true;
    final hasCapture = _captured != null;
    return Scaffold(
      backgroundColor: FaceIdColors.navyDeep,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            CoverCameraPreview(controller: _cam!)
          else if (_initializing)
            const Center(
                child: CircularProgressIndicator(color: FaceIdColors.accent))
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                    _error ?? t('Camera unavailable.', 'Hindi available ang camera.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
            ),
          if (ready)
            Builder(
              builder: (context) {
                // A fixed 260px circle read tiny on a tablet or a phone in
                // landscape — size off the shorter screen dimension
                // instead so it always frames a comfortable fraction of
                // the preview, clamped so it never gets absurdly huge on a
                // large display either.
                final shortest = MediaQuery.of(context).size.shortestSide;
                final width = (shortest * 0.62).clamp(200.0, 300.0);
                final height = width * 1.25;
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Instruction right above the circle — visible
                      // immediately (not just while a scan is running).
                      if (!hasCapture)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(_instruction,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                        ),
                      FaceOvalScanner(
                        width: width,
                        height: height,
                        scanning: _capturing,
                        success: hasCapture,
                      ),
                    ],
                  ),
                );
              },
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconButton(
                        onPressed: _closeOrSignOut,
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('FaceID',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 2),
                              Text(
                                  hasCapture
                                      ? t('Face Captured', 'Nakuha ang mukha')
                                      : t('Follow the prompt below',
                                          'Sundin ang tagubilin sa ibaba'),
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ready)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 40, vertical: 16),
                      child: ScanProgressBar(
                        progress: _progress,
                        caption: hasCapture
                            ? t('Captured', 'Nakuha na')
                            : (_capturing ? t('Scanning.', 'Sina-scan.') : null),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_error != null && ready) ...[
                            Text(_error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Color(0xFFFF6B6B),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                          ],
                          if (!hasCapture)
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed:
                                    (!ready || _capturing) ? null : _capture,
                                style: FilledButton.styleFrom(
                                  backgroundColor: FaceIdColors.accent,
                                  foregroundColor: FaceIdColors.navyDeep,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(999)),
                                ),
                                icon: _capturing
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: FaceIdColors.navyDeep),
                                      )
                                    : const Icon(Icons.face_retouching_natural),
                                label: Text(
                                    _capturing
                                        ? t('Reading...', 'Binabasa...')
                                        : t('Capture', 'Kumuha ng Larawan'),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                              ),
                            )
                          else
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton(
                                    onPressed: _saving
                                        ? null
                                        : () => setState(() {
                                              _captured = null;
                                              _progress = 0;
                                            }),
                                    style: FilledButton.styleFrom(
                                      // Same solid amber fill as "Save
                                      // Face ID" right next to it (not an
                                      // outline anymore) — onAccent is
                                      // near-black, giving the requested
                                      // black-on-orange look.
                                      backgroundColor: YosColors.accentDeep,
                                      foregroundColor: YosColors.onAccent,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(999)),
                                    ),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(t('Retake', 'Ulitin'),
                                          maxLines: 1,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: _saving ? null : _save,
                                    style: FilledButton.styleFrom(
                                      // YosColors.accentDeep/onAccent — the
                                      // app's actual brand amber, the same
                                      // pairing the sign-in screen's "Scan
                                      // Face ID" button uses (see
                                      // BreathingGlowButton's defaults),
                                      // not this screen's own one-off mint
                                      // accent or an unrelated green.
                                      backgroundColor: YosColors.accentDeep,
                                      foregroundColor: YosColors.onAccent,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(999)),
                                    ),
                                    child: _saving
                                        ? SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: YosColors.onAccent),
                                          )
                                        : FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                                t('Save Face ID',
                                                    'I-save ang Face ID'),
                                                maxLines: 1,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w800)),
                                          ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
