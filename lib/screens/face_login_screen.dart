import 'dart:async';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
import '../widgets/app_dialog.dart';
import '../widgets/scanner_frame.dart';
import '../widgets/toast.dart';
import 'password_login_screen.dart';
import 'root_shell.dart';

/// Face sign-in: matches the camera against collector profiles enrolled on
/// this device, then completes a real Firebase sign-in with the matched
/// profile's stored credential. See FaceAuthService's class doc for the
/// security model this rests on.
///
/// LoginScreen's only sign-in action pushes this with no [expectedEmail] —
/// there's no phone number typed anymore to narrow the candidate down to,
/// so it identifies *whoever* this face belongs to among every profile
/// enrolled on this device (1:N). [expectedEmail] (1:1 verification against
/// one known profile) is kept for any future caller that already knows
/// which account this should be, but nothing currently passes it.
/// LoginScreen's Collector/Admin toggle (shown before ever reaching this
/// screen) selects one of these and passes it in as [FaceLoginScreen.role].
enum SignInRole { collector, admin }

class FaceLoginScreen extends StatefulWidget {
  const FaceLoginScreen({
    super.key,
    this.expectedEmail,
    this.role = SignInRole.collector,
  });

  final String? expectedEmail;

  /// Purely a shortcut for intent, exactly like the old password
  /// LoginScreen's role picker was — the face match alone decides who
  /// signs in; this only changes which toast plays afterward (see _scan)
  /// if the matched account's real is_admin doesn't agree with it. Never
  /// gates or filters the scan itself.
  final SignInRole role;

  @override
  State<FaceLoginScreen> createState() => _FaceLoginScreenState();
}

class _FaceLoginScreenState extends State<FaceLoginScreen> {
  CameraController? _cam;
  FaceDetector? _fd;

  bool _initializing = true;
  bool _busy = false;
  String? _error;
  String? _matchedName;
  double _progress = 0;

  // Login targets a single good frame, not an average of several like
  // FaceEnrollScreen does — enrollment is a one-time setup where a sturdier
  // averaged template is worth the extra seconds; login happens every
  // sign-in, so it's tuned for mobile-unlock-speed instead: one frame that
  // passes FaceGeometry.qualityIssue is enough to compare against the
  // already-averaged enrolled template. This cap is just a retry ceiling
  // for bad frames (no face found, blinking, off-angle) — the loop breaks
  // the moment a single good one lands, well before this limit in the
  // common case.
  static const _maxAttempts = 6;

  @override
  void initState() {
    super.initState();
    // Fired without awaiting: this is a background hardening pass, not
    // something the camera/permission setup below should ever wait on.
    // Runs before any scan attempt gets a chance to complete, so a
    // deleted account's face is purged from this device before it could
    // ever be a match candidate at all, not just cleaned up after
    // already winning one.
    unawaited(FaceAuthService.instance.pruneStaleProfiles());
    _init();
  }

  Future<void> _init() async {
    if (kIsWeb) {
      setState(() {
        _initializing = false;
        _error = t('Face sign-in is only available on the Android app.',
            'Available lang ang Face sign-in sa Android app.');
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
    // time the app ever asks for the camera. One short settle-and-retry
    // clears it; a real failure (no camera, hardware busy, etc.) still
    // surfaces normally on the retry.
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
        unawaited(_autoLoop());
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

  /// Scans continuously the moment the camera's ready — no tap needed,
  /// just face the phone. Runs [_scan] back-to-back with a short pause
  /// between attempts, so holding still in frame gets recognized within
  /// the first cycle or two rather than waiting on a manual "Scan" tap.
  /// Skips actually scanning (camera capture + ML inference) whenever
  /// this screen isn't the visible top route — e.g. while "Type password
  /// instead" is pushed on top of it — so it doesn't keep burning battery
  /// and camera cycles, or worse, complete a stray sign-in, in the
  /// background; it resumes as soon as this becomes current again. Stops
  /// entirely once the widget is unmounted (a successful scan navigates
  /// away, as does an unrecognized-face denial — see
  /// [_denyAndReturnToLogin]).
  Future<void> _autoLoop() async {
    while (mounted) {
      if (!mounted) return;
      final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
      if (isCurrent) await _scan();
      if (!mounted) return;
      await Future.delayed(Duration(milliseconds: isCurrent ? 900 : 400));
    }
  }

  /// A face was conclusively read this attempt and doesn't belong to any
  /// currently-real account — not locally, and not in the cloud fallback
  /// either (see _tryCloudMatch), or a match whose account has since been
  /// removed. Unlike a merely unclear frame (no face found, blinking,
  /// off-angle — [_autoLoop] just quietly retries those), this is a real,
  /// blocking answer: show it as an alert rather than inline text.
  ///
  /// Doesn't assume this means "never registered" — it's just as likely a
  /// real, already-enrolled collector who simply isn't matching right now
  /// (poor lighting, no connectivity for the cloud lookup, etc.), so the
  /// way out offered here is the password fallback every real account
  /// already has, not a push toward creating a brand-new one.
  Future<void> _denyAndReturnToLogin() async {
    if (!mounted) return;
    final usePassword = await showAppConfirmDialog(
      context,
      barrierDismissible: false,
      title: t('Not Recognized', 'Hindi Nakilala'),
      message: t(
          'We couldn\'t match your face this time. You can sign in '
          'with your password instead.',
          'Hindi namin natugma ang iyong mukha ngayon. Puwede kang mag-sign '
          'in gamit ang iyong password.'),
      confirmLabel: t('Type Password Instead', 'I-type na lang ang password'),
      confirmIcon: Icons.password_rounded,
    );
    if (!mounted) return;
    if (usePassword == true) {
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const PasswordLoginScreen()));
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _scan() async {
    final cam = _cam;
    final fd = _fd;
    if (cam == null || fd == null || !cam.value.isInitialized || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _matchedName = null;
      _progress = 0;
    });
    try {
      var profiles = await FaceAuthService.instance.loadProfiles();
      if (widget.expectedEmail != null) {
        // Targeted (1:1) path — only this one account's profile is a
        // legitimate match, never any other face enrolled on this device.
        profiles =
            profiles.where((p) => p.email == widget.expectedEmail).toList();
      }
      // No early "nothing enrolled here" bailout anymore — a phone that's
      // never seen this collector locally still needs to capture a frame
      // so the cloud fallback below (see _tryCloudMatch) has something to
      // compare it against.

      String? issue = t('No face found. Center your face in the frame.',
          'Walang nakitang mukha. I-center ang iyong mukha sa frame.');
      List<double>? vector;
      for (var attempt = 1;
          attempt <= _maxAttempts && vector == null;
          attempt++) {
        // A brief settle before every shot (not scaling with attempt
        // number) — just enough for the camera's auto-exposure/focus to
        // catch up, short enough that a good first frame still lands well
        // under a second.
        await Future.delayed(const Duration(milliseconds: 120));
        final shot = await cam.takePicture();
        final faces = await fd.processImage(InputImage.fromFilePath(shot.path));
        if (faces.isEmpty) {
          issue = t('No face found. Center your face in the frame.',
              'Walang nakitang mukha. I-center ang iyong mukha sa frame.');
          continue;
        }
        if (faces.length > 1) {
          issue = t('More than one face in frame.',
              'Higit sa isang mukha ang nasa frame.');
          continue;
        }
        // strict: false — login only needs one reasonable frame to feed
        // the real security boundary (bestMatch's cosine-similarity
        // check below), so a recognized face isn't bounced by the same
        // tight pose gate enrollment uses for its one-time template.
        final q = FaceGeometry.qualityIssue(faces.first, strict: false);
        if (q != null) {
          issue = q;
          continue;
        }
        final v = await FaceEmbeddingService.instance
            .extractEmbeddingFromFile(shot.path, faces.first);
        if (v == null) {
          issue = t('Couldn\'t read your face clearly. Try again.',
              'Hindi maliwanag nabasa ang iyong mukha. Subukan ulit.');
          continue;
        }
        vector = v;
        if (mounted) setState(() => _progress = 1.0);
      }

      if (vector == null) {
        setState(() {
          _error = issue;
          _progress = 0;
        });
        return;
      }

      final match = FaceAuthService.instance.bestMatch(vector, profiles);
      // Temporary tuning aid: bestMatch only reports a similarity for a
      // profile that already passed the threshold, so this is the only
      // way to see how close a *rejected* attempt actually was — remove
      // once FaceEmbeddingService.matchThreshold is confirmed against
      // real captures.
      debugPrint('Face ID closest similarity this attempt: '
          '${FaceAuthService.instance.closestSimilarity(vector, profiles)} '
          '(threshold ${FaceEmbeddingService.matchThreshold}, '
          'matched: ${match != null})');

      if (match != null) {
        // A match is only a candidate, not a confirmed identity — don't
        // show "Welcome back" or the success checkmark until the real
        // credential check (the actual security boundary) has genuinely
        // succeeded below; showing it beforehand would flash a false
        // success for the wrong person even when they're correctly never
        // signed in.
        await YosRepository.instance
            .login(match.profile.email, match.profile.password);
        await _afterLogin(uid: match.profile.uid, name: match.profile.name);
        return;
      }

      // No local match — including "nothing enrolled on this phone at
      // all". This face might still belong to a real collector who's
      // simply never used THIS device before (see YosRepository.
      // syncFaceEmbedding / FaceEnrollScreen._save), so check the shared
      // cloud directory before giving up on it.
      final cloudMatch = await _tryCloudMatch(vector);
      if (cloudMatch == null) {
        await _denyAndReturnToLogin();
        return;
      }

      if (!mounted) return;
      final password = await _promptPassword(cloudMatch.profile.name);
      if (password == null) return; // cancelled — stay on this screen

      try {
        await YosRepository.instance.login(cloudMatch.profile.email, password);
      } on FirebaseAuthException {
        if (mounted) {
          setState(() => _error = t('Incorrect password. Please try again.',
              'Maling password. Subukan ulit.'));
        }
        return;
      }

      // Sign-in just genuinely succeeded — cache the credential and this
      // capture on THIS device too, exactly like a normal enrollment
      // would. Every Face ID attempt for this account, on this phone,
      // takes the fast local path above from now on instead of this
      // cloud one.
      await FaceAuthService.instance.enroll(
        uid: cloudMatch.profile.uid,
        name: cloudMatch.profile.name,
        email: cloudMatch.profile.email,
        password: password,
        embedding: vector,
      );
      await _afterLogin(
          uid: cloudMatch.profile.uid, name: cloudMatch.profile.name);
    } on FirebaseAuthException {
      if (mounted) {
        setState(() => _error = t(
            'Face matched, but the saved sign-in is out of date. Use your password instead.',
            'Nakilala ang mukha, pero luma na ang naka-save na sign-in. '
            'Gamitin na lang ang password mo.'));
      }
    } catch (e) {
      // Never surface a raw exception (e.g. a transient Firestore
      // permission-denied that outlasted markFaceIdEnrolled's own retries)
      // to the user — log it for diagnostics, show a plain retry prompt.
      debugPrint('Face sign-in failed: $e');
      if (mounted) {
        setState(() => _error = t('Something went wrong. Please try again.',
            'May nangyaring mali. Subukan ulit.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Looks a captured embedding up against every collector's cloud-synced
  /// face (see YosRepository.syncFaceEmbedding) — the fallback [_scan]
  /// only reaches once no *local* profile on this phone matches. Needs a
  /// moment of connectivity and at least an anonymous session to satisfy
  /// firestore.rules' face_profiles read rule, since there's no real
  /// sign-in yet at this point on an unfamiliar device (see
  /// main.dart's `home` StreamBuilder, which deliberately ignores an
  /// anonymous session so this blip never disrupts navigation). Returns
  /// null on any failure — offline, or the Firebase project's Anonymous
  /// sign-in provider not enabled — rather than surfacing it; the caller
  /// just falls back to the normal "not recognized" outcome either way.
  Future<CloudFaceMatch?> _tryCloudMatch(List<double> vector) async {
    try {
      await FirebaseAuth.instance.signInAnonymously();
      final cloud = await YosRepository.instance.fetchCloudFaceProfiles();
      await FirebaseAuth.instance.signOut();
      final candidates = widget.expectedEmail == null
          ? cloud
          : cloud.where((p) => p.email == widget.expectedEmail).toList();
      return FaceAuthService.instance.bestCloudMatch(vector, candidates);
    } catch (e) {
      debugPrint('Cloud face lookup unavailable: $e');
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
      return null;
    }
  }

  /// One-time password confirmation for a face recognized only via
  /// [_tryCloudMatch] — this phone has no cached credential for [name]
  /// yet, so a real sign-in still needs the actual password once.
  /// Returns the typed password, or null if the collector cancels.
  Future<String?> _promptPassword(String name) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PasswordPromptDialog(name: name),
    );
  }

  /// Shared tail once a real Firebase sign-in has already succeeded for
  /// [uid]/[name] — run identically whether that sign-in came from a
  /// local match's cached credential or a cloud match's freshly-typed
  /// password, so both paths reach the dashboard the same way.
  Future<void> _afterLogin({required String uid, required String name}) async {
    // A matched profile is only a candidate for a *currently real*
    // account. Verify against Firestore before ever trusting it, and
    // purge it locally the moment it's found stale — this is what keeps
    // a removed collector's face from signing back into an account the
    // app otherwise considers gone, on any device. Must run *after*
    // login() has already succeeded, not before: reading another
    // account's collectors/{uid} doc is only allowed once actually
    // signed in as that uid (or as an admin) per firestore.rules.
    final stillExists = await YosRepository.instance.collectorExists(uid);
    if (!stillExists) {
      await FaceAuthService.instance.removeProfile(uid);
      await YosRepository.instance.logout();
      await _denyAndReturnToLogin();
      return;
    }

    // A real Face ID sign-in just succeeded, which is itself proof this
    // account has Face ID enrolled — backfills the mandatory gate's flag
    // for an account that enrolled a face before that flag existed (or
    // on the rare chance it never synced), instead of RootShell wrongly
    // sending an already-working account back through enrollment. Safe
    // to call unconditionally: setting an already-true flag to true
    // again is a no-op per firestore.rules. Fire-and-forget, same as the
    // audit entry below — neither should add a Firestore round trip to
    // how fast a matched face reaches the dashboard, and a transient
    // failure in either is never this sign-in's problem.
    unawaited(YosRepository.instance.markFaceIdEnrolled().catchError((_) {}));
    unawaited(YosRepository.instance
        .logAudit(AuditAction.faceLoginSuccess, 'Signed in via Face ID')
        .catchError((_) {}));
    if (!mounted) return;
    setState(() {
      _matchedName = name;
      _progress = 1.0;
    });
    // Correct face always gets in — the role toggle is a shortcut for
    // intent, not a second credential. A mismatch (matched a Collector
    // while Admin was selected, or vice versa) doesn't block sign-in; it
    // just says so, since the account's real is_admin flag is what
    // actually governs access everywhere past this screen anyway. Same
    // behavior the old password LoginScreen's role picker had.
    final actuallyAdmin = await YosRepository.instance.isCurrentUserAdmin();
    if (!mounted) return;
    // The login() above already fired Firebase's real-user auth state
    // change, which main.dart's own top-level StreamBuilder reacts to by
    // swapping its entire `home` to RootShell — that can land *before*
    // this screen's own navigation below does, since everything from
    // here up has been real async work (a Firestore read or two) the
    // swap doesn't have to wait for. When that happens this screen's own
    // Navigator/Overlay is already gone even though `mounted` still read
    // true a line above (Flutter's element teardown isn't necessarily
    // synchronous with the ancestor swap that triggers it), so
    // Navigator.of(context) here can throw. That's harmless, not a real
    // failure: main.dart's swap already delivered the same account to
    // the same destination on its own — this push is a (now redundant)
    // optimization attempt, not the only way there.
    try {
      if ((widget.role == SignInRole.admin) != actuallyAdmin) {
        Toast.info(
            context,
            actuallyAdmin
                ? t('Signed in as Admin (this account has admin access).',
                    'Naka-sign in bilang Admin (may admin access ang account na ito).')
                : t('Signed in as Collector (this account isn\'t Admin).',
                    'Naka-sign in bilang Kolektor (hindi Admin ang account na ito).'));
      } else {
        Toast.success(context, t('Welcome back, $name', 'Maligayang pagbabalik, $name'));
      }
      // skipEnrollCheck: this scan already proved enrollment — there's no
      // local profile to have matched otherwise — so RootShell doesn't
      // need to re-derive that via its own (racy, right after the
      // sign-in above) Firestore read.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => const RootShell(skipEnrollCheck: true)),
        (_) => false,
      );
    } catch (e) {
      debugPrint('Post-sign-in navigation raced main.dart\'s own '
          'auth-state swap (harmless — already handled): $e');
    }
  }

  @override
  void dispose() {
    _cam?.dispose();
    _fd?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _cam?.value.isInitialized == true;
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
                final shortest = MediaQuery.of(context).size.shortestSide;
                final width = (shortest * 0.62).clamp(200.0, 300.0);
                final height = width * 1.25;
                return Stack(
                  children: [
                    Center(
                      child: FaceOvalScanner(
                        width: width,
                        height: height,
                        scanning: _busy,
                        success: _matchedName != null,
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
                        onPressed: () => Navigator.of(context).pop(),
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
                                  _matchedName != null
                                      ? t('Welcome back, $_matchedName',
                                          'Maligayang pagbabalik, $_matchedName')
                                      : t(
                                          'Please look into the camera and hold still',
                                          'Tumingin sa camera at huwag gumalaw'),
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
                        caption: _matchedName != null
                            ? t('Matched', 'Nakilala')
                            : (_busy ? t('Scanning.', 'Sina-scan.') : null),
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
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: (!ready || _busy) ? null : _scan,
                              style: FilledButton.styleFrom(
                                // YosColors.accentDeep/onAccent — the same
                                // amber pairing "Scan Face ID" (the
                                // sign-in landing screen) and "Save Face
                                // ID"/"Retake" (enrollment) all use now,
                                // not this screen's own mint accent.
                                backgroundColor: YosColors.accentDeep,
                                foregroundColor: YosColors.onAccent,
                                // Explicit disabled colors, not left unset:
                                // FilledButton falls back to the app-wide
                                // filledButtonTheme's disabledBackground/
                                // ForegroundColor otherwise (see
                                // core/theme.dart) — a flat, unrelated gray
                                // — for the "Checking..." state this button
                                // sits in while auto-scanning is busy
                                // (onPressed: null above). A dimmed amber
                                // instead keeps it reading as the same
                                // button rather than a suddenly-disabled
                                // stranger.
                                disabledBackgroundColor:
                                    YosColors.accentDeep.withValues(alpha: 0.5),
                                disabledForegroundColor:
                                    YosColors.onAccent.withValues(alpha: 0.75),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
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
                                  : const Icon(Icons.face_retouching_natural),
                              label: Text(
                                  _busy
                                      ? t('Checking...', 'Chine-check...')
                                      : t('Scan', 'I-scan'),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                            ),
                          ),
                          // Only offered once a scan has actually failed —
                          // never up front, so Face ID stays the path
                          // everyone reaches for first. Recover access
                          // isn't duplicated here — PasswordLoginScreen has
                          // its own "Forgot password?" going to the same
                          // place, one level deeper is enough.
                          if (_error != null) ...[
                            const SizedBox(height: 10),
                            TextButton(
                              onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const PasswordLoginScreen())),
                              style: TextButton.styleFrom(
                                  foregroundColor: FaceIdColors.accent),
                              child: Text(t('Type Password Instead',
                                  'I-type na lang ang password')),
                            ),
                          ],
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

/// Password confirmation dialog for [_FaceLoginScreenState._promptPassword]
/// — a plain [StatefulWidget] rather than a [showDialog] builder closure
/// only because the obscure-text toggle needs its own local state.
class _PasswordPromptDialog extends StatefulWidget {
  const _PasswordPromptDialog({required this.name});

  final String name;

  @override
  State<_PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<_PasswordPromptDialog> {
  // Owned by this dialog's own State so it's disposed only once this
  // Element actually unmounts — i.e. after the dialog route's closing
  // animation finishes. Disposing it any earlier (e.g. by the caller,
  // right after showDialog's Future resolves) yanks the controller out
  // from under the TextField while it's still on-screen mid-fade-out,
  // which throws "used after being disposed" during that frame's build
  // and cascades into the widgets-library "'_dependents.isEmpty': is
  // not true" assertion as a secondary failure.
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
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
                      t('Welcome back, ${widget.name}',
                          'Maligayang pagbabalik, ${widget.name}'),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: YosColors.ink)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: YosColors.sub),
                  tooltip: t('Cancel', 'Kanselahin'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(
                      'Recognized for the first time on this phone — enter your '
                      'password once to finish signing in. Face ID will be '
                      'instant on this phone from then on.',
                      'Unang beses kang nakilala sa telepono na ito — ilagay '
                      'ang iyong password nang isang beses para matapos ang '
                      'sign in. Instant na ang Face ID sa teleponong ito '
                      'mula ngayon.'),
                  style: TextStyle(
                      color: YosColors.sub,
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  autofocus: true,
                  onSubmitted: (v) => Navigator.of(context).pop(v),
                  decoration: InputDecoration(
                    labelText: t('Password', 'Password'),
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Material(
              color: YosColors.accent,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: () => Navigator.of(context).pop(_password.text),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  alignment: Alignment.center,
                  child: Text(t('Continue', 'Magpatuloy'),
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
