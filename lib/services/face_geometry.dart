import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Pose/eye-open quality gate applied to a captured frame before it's
/// used for face matching — independent of *how* the resulting vector is
/// computed, so this stays in use across the matching-engine upgrade to
/// FaceEmbeddingService (see that file's doc comment for why the vector
/// computation itself moved out of here).
class FaceGeometry {
  FaceGeometry._();

  /// Landmarks checked for presence — if ML Kit can't find these on a
  /// near-frontal, well-lit capture, the frame isn't usable regardless of
  /// which descriptor algorithm processes it afterward.
  static const _points = [
    FaceLandmarkType.leftEye,
    FaceLandmarkType.rightEye,
    FaceLandmarkType.noseBase,
    FaceLandmarkType.leftMouth,
    FaceLandmarkType.rightMouth,
    FaceLandmarkType.bottomMouth,
    FaceLandmarkType.leftCheek,
    FaceLandmarkType.rightCheek,
  ];

  /// Landmarks a quick login scan needs to align/crop the face (see
  /// FaceEmbeddingService._alignFace) — a looser bar than [_points], which
  /// enrollment requires in full since its template gets reused for every
  /// future login comparison.
  static const _loginPoints = [
    FaceLandmarkType.leftEye,
    FaceLandmarkType.rightEye,
    FaceLandmarkType.noseBase,
  ];

  /// Why a frame can't be used yet, or null if it's good to capture.
  ///
  /// [strict] tunes how forgiving this is: enrollment (the default) stays
  /// strict because that one captured template is what every future login
  /// gets compared against for as long as this device has this account
  /// enrolled — worth a few extra seconds and retries to get a clean,
  /// frontal, eyes-open frame. Login instead passes `strict: false` — the
  /// real security boundary is [FaceEmbeddingService.matchThreshold] on the
  /// resulting embedding, not this pose gate, so a recognized face should
  /// clear it on the first reasonable frame and reach the dashboard
  /// immediately rather than being bounced for a slight tilt or a partial
  /// blink.
  static String? qualityIssue(Face face, {bool strict = true}) {
    final yaw = face.headEulerAngleY ?? 0;
    final roll = face.headEulerAngleZ ?? 0;
    final maxAngle = strict ? 12.0 : 25.0;
    if (yaw.abs() > maxAngle) return 'Face the camera straight on';
    if (roll.abs() > maxAngle) return 'Straighten your head';

    final minEyeOpen = strict ? 0.4 : 0.2;
    final leftOpen = face.leftEyeOpenProbability;
    final rightOpen = face.rightEyeOpenProbability;
    if (leftOpen != null && leftOpen < minEyeOpen) return 'Open your eyes';
    if (rightOpen != null && rightOpen < minEyeOpen) return 'Open your eyes';

    for (final t in strict ? _points : _loginPoints) {
      if (face.landmarks[t] == null) return 'Move closer and center your face';
    }
    return null;
  }
}
