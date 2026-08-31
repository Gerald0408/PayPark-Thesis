import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/transaction.dart';
import '../services/face_auth_service.dart';
import '../services/face_embedding_service.dart';
import '../services/face_geometry.dart';
import '../services/firestore_service.dart';
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

  bool _showIntro = true;
  bool _initializing = true;
  bool _capturing = false;
  bool _saving = false;
  String? _error;
  List<double>? _captured;
  double _progress = 0;

  // More attempts than strictly needed to find one good frame — every
  // frame that passes quality gets averaged together (see
  // FaceEmbeddingService.average), so more good frames means a steadier
  // template. Tuned down from 5 to keep the whole capture inside a ~3-5s
  // budget — kept in step with FaceLoginScreen's _maxAttempts.
  static const _maxAttempts = 4;

  /// Camera/ML Kit init is deferred until "Get Started" is tapped on the
  /// intro splash, rather than firing (and asking for camera permission)
  /// the instant this screen opens.
  Future<void> _getStarted() async {
    setState(() => _showIntro = false);
    await _init();
  }

  Future<void> _init() async {
    if (kIsWeb) {
      setState(() {
        _initializing = false;
        _error = 'Face capture is only available on the Android app.';
      });
      return;
    }
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = status.isPermanentlyDenied
            ? 'Camera blocked. Settings > Apps > PayPark > Permissions > Camera'
            : 'Camera permission denied.';
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
    for (var attempt = 0; ; attempt++) {
      try {
        final cams = await availableCameras();
        if (cams.isEmpty) {
          if (mounted) {
            setState(() {
              _initializing = false;
              _error = 'No camera found.';
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
            _error = 'Camera error: $e';
          });
        }
        return;
      }
    }
  }

  Future<void> _capture() async {
    final cam = _cam;
    final fd = _fd;
    if (cam == null || fd == null || !cam.value.isInitialized || _capturing) {
      return;
    }
    setState(() {
      _capturing = true;
      _error = null;
      _progress = 0;
    });
    try {
      String? issue = 'No face found. Center your face in the frame.';
      final vectors = <List<double>>[];
      for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
        await Future.delayed(Duration(milliseconds: 100 + attempt * 50));
        final shot = await cam.takePicture();
        final faces = await fd.processImage(InputImage.fromFilePath(shot.path));
        if (faces.isEmpty) {
          issue = 'No face found. Center your face in the frame.';
          continue;
        }
        if (faces.length > 1) {
          issue = 'More than one face in frame.';
          continue;
        }
        // strict: true (the default) — this capture becomes the template
        // every future login gets compared against, so it's worth holding
        // enrollment to a tighter pose/eyes-open bar than login uses.
        final q = FaceGeometry.qualityIssue(faces.first, strict: true);
        if (q != null) {
          issue = q;
          continue;
        }
        final v = await FaceEmbeddingService.instance
            .extractEmbeddingFromFile(shot.path, faces.first);
        if (v == null) {
          issue = 'Couldn\'t read your face clearly. Try again.';
          continue;
        }
        vectors.add(v);
        if (mounted) {
          setState(() => _progress = vectors.length / _maxAttempts);
        }
      }
      final vector =
          vectors.isEmpty ? null : FaceEmbeddingService.average(vectors);
      if (!mounted) return;
      setState(() {
        _captured = vector;
        _error = vector == null ? issue : null;
        _progress = vector == null ? 0 : 1.0;
      });
    } catch (e) {
      debugPrint('Face capture failed: $e');
      if (mounted) {
        setState(() => _error = 'Capture failed. Please try again.');
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
            .logAudit(AuditAction.faceEnroll, 'Face ID enrolled on device');
      } catch (_) {}
      if (!mounted) return;
      Toast.success(context, 'Face ID saved');
      widget.onFinished(context);
    } catch (e) {
      // Same rule as everywhere else here: never surface a raw exception
      // (e.g. a transient Firestore permission-denied that outlasted
      // markFaceIdEnrolled's own retries) to the user.
      debugPrint('Face ID save failed: $e');
      if (mounted) {
        setState(() => _error = 'Couldn\'t save Face ID. Please try again.');
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
    if (_showIntro) {
      return Scaffold(
        body: FaceIdIntro(
          description: 'FaceID lets you sign in with your face instead of '
              'typing your password every time. We\'ll capture a few '
              'frames now and link them to your account, on this device '
              'only.',
          onGetStarted: _getStarted,
          onClose: _closeOrSignOut,
        ),
      );
    }

    final ready = _cam?.value.isInitialized == true;
    final hasCapture = _captured != null;
    return Scaffold(
      backgroundColor: FaceIdColors.navyDeep,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            CameraPreview(_cam!)
          else if (_initializing)
            const Center(
                child: CircularProgressIndicator(color: FaceIdColors.accent))
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_error ?? 'Camera unavailable.',
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
                return Stack(
                  children: [
                    Center(
                      child: FaceOvalScanner(
                        width: width,
                        height: height,
                        scanning: _capturing,
                        success: hasCapture,
                      ),
                    ),
                  ],
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
                                      ? 'Face captured'
                                      : 'Please look into the camera and hold still',
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
                            ? 'Captured'
                            : (_capturing ? 'Scanning.' : null),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: FaceIdColors.navyMid,
                        borderRadius: BorderRadius.circular(24),
                      ),
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
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 16),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(999)),
                                ),
                                icon: _capturing
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: FaceIdColors.navyDeep),
                                      )
                                    : const Icon(
                                        Icons.face_retouching_natural),
                                label: Text(
                                    _capturing ? 'Reading...' : 'Capture',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                              ),
                            )
                          else
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _saving
                                        ? null
                                        : () => setState(() {
                                              _captured = null;
                                              _progress = 0;
                                            }),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: const BorderSide(
                                          color: Colors.white30),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(999)),
                                    ),
                                    child: const FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text('Retake',
                                          maxLines: 1,
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: _saving ? null : _save,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: FaceIdColors.good,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(999)),
                                    ),
                                    child: _saving
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white),
                                          )
                                        : const FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text('Save Face ID',
                                                maxLines: 1,
                                                style: TextStyle(
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
