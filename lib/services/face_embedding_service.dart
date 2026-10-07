import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'tflite_interpreter.dart';

/// MobileFaceNet-based face embedding engine — the collector app's real
/// Face ID matching algorithm, replacing the earlier landmark-geometry
/// descriptor (see FaceGeometry, now reduced to just its pose/eye-open
/// [FaceGeometry.qualityIssue] gate, which is still useful regardless of
/// which descriptor computes the actual vector).
///
/// This only changes *how the vector is computed* — embeddings still live
/// exactly where they always did: device-local only, via
/// [FaceAuthService]/flutter_secure_storage.
class FaceEmbeddingService {
  FaceEmbeddingService._();
  static final FaceEmbeddingService instance = FaceEmbeddingService._();

  static const _inputSize = 112;
  // The bundled model (MCarlomagno/FaceRecognitionAuth's mobilefacenet.tflite,
  // BSD-3-Clause) outputs a 192-d embedding, not the 128-d that's more
  // commonly quoted for MobileFaceNet in papers — verified against this
  // exact file's documented spec, not assumed.
  static const _embeddingSize = 192;

  /// Minimum cosine similarity (see [cosineSimilarity]) two embeddings
  /// must share to count as the same person — 0.82 sits in the middle of
  /// this model's practical "same person under normal lighting" range
  /// (roughly 0.80–0.85 is the commonly cited operating point for this
  /// class of face embedding): strict enough that a stranger's face
  /// shouldn't cross it, loose enough that ordinary lighting/angle
  /// variation on a genuine match still does. Watch
  /// [FaceAuthService.closestSimilarity] logs during field use and
  /// adjust — raise it if a false accept is ever observed; if a
  /// genuinely enrolled face keeps getting rejected under otherwise
  /// normal conditions, lower it a little rather than a lot (don't drop
  /// below ~0.75 — a match here signs someone in for real).
  static const double matchThreshold = 0.82;

  Interpreter? _interpreter;

  Future<void> loadModel() async {
    // tflite_flutter's Interpreter.fromAsset calls rootBundle.load()
    // directly, so this must be the *full* asset key exactly as declared
    // in pubspec.yaml (assets/models/mobilefacenet.tflite) — not that
    // path with the "assets/" prefix stripped off, which just looks like
    // a missing-asset error at runtime instead of a wrong-path one.
    _interpreter ??= await Interpreter.fromAsset(
      'assets/models/mobilefacenet.tflite',
    );
  }

  bool get isModelLoaded => _interpreter != null;

  /// Decodes the JPEG at [imagePath] — a camera `takePicture()` capture —
  /// crops [face]'s bounding box out of it, resizes to 112x112, normalizes,
  /// and runs it through MobileFaceNet. Returns null if the file can't be
  /// decoded or the crop is empty.
  Future<List<double>?> extractEmbeddingFromFile(
    String imagePath,
    Face face,
  ) async {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('FaceEmbeddingService.loadModel() not called yet');
    }
    final bytes = await File(imagePath).readAsBytes();
    var decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    // ML Kit's face detector reads the file's EXIF orientation and reports
    // face.boundingBox in the resulting *upright* coordinate space — but
    // img.decodeImage does NOT auto-rotate pixels to match EXIF (it only
    // stores the tag as metadata), so without this, the bounding box and
    // the raw pixel buffer are in two different rotated coordinate
    // spaces. Cropping unbaked would grab the wrong region entirely on
    // any capture with EXIF rotation set (common for Android front
    // cameras), producing a garbage, non-discriminative face crop — this
    // was silently breaking every embedding, not just an edge case.
    decoded = img.bakeOrientation(decoded);

    final cropped = _alignFace(decoded, face) ??
        _cropToBoundingBox(decoded, face.boundingBox);
    if (cropped == null || cropped.width == 0 || cropped.height == 0) {
      return null;
    }

    final resized = img.copyResize(
      cropped,
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.linear,
    );
    return _runInference(interpreter, resized);
  }

  img.Image? _cropToBoundingBox(img.Image source, Rect box) {
    final x = box.left.clamp(0, source.width - 1).toInt();
    final y = box.top.clamp(0, source.height - 1).toInt();
    final w = box.width.clamp(1, source.width - x).toInt();
    final h = box.height.clamp(1, source.height - y).toInt();
    if (w <= 0 || h <= 0) return null;
    return img.copyCrop(source, x: x, y: y, width: w, height: h);
  }

  /// Rotates a crop so the eye line is level before it ever reaches the
  /// model — MobileFaceNet (like most face-embedding networks) was trained
  /// on eye-aligned faces, so a plain axis-aligned bounding-box crop feeds
  /// it a meaningfully different-looking input for the same person if
  /// their head is tilted differently than it was during enrollment, even
  /// though the quality gate already keeps both within a narrow
  /// near-frontal band (see FaceGeometry.qualityIssue). Falls back to null
  /// (the caller then uses the plain crop) if eye landmarks aren't
  /// available for this frame.
  img.Image? _alignFace(img.Image source, Face face) {
    final left = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final right = face.landmarks[FaceLandmarkType.rightEye]?.position;
    if (left == null || right == null) return null;

    final box = face.boundingBox;
    // Crop a generously oversized square around the face first — rotating
    // a tightly-cropped face would clip its corners out of frame.
    final side = math.max(box.width, box.height) * 1.8;
    final cx = box.left + box.width / 2;
    final cy = box.top + box.height / 2;
    final ex = (cx - side / 2).clamp(0, source.width - 1).toDouble();
    final ey = (cy - side / 2).clamp(0, source.height - 1).toDouble();
    final ew = side.clamp(1, source.width - ex);
    final eh = side.clamp(1, source.height - ey);
    if (ew <= 0 || eh <= 0) return null;
    final expanded = img.copyCrop(source,
        x: ex.toInt(), y: ey.toInt(), width: ew.toInt(), height: eh.toInt());

    // The angle between the two eyes is all that matters here — it's the
    // same value regardless of which eye ML Kit calls "left" vs "right".
    final dx = (right.x - left.x).toDouble();
    final dy = (right.y - left.y).toDouble();
    final angleDeg = math.atan2(dy, dx) * 180 / math.pi;
    final rotated = img.copyRotate(expanded,
        angle: -angleDeg, interpolation: img.Interpolation.linear);

    // copyRotate rotates around its own center and expands the canvas to
    // fit, so the face — already centered in `expanded` — is still
    // centered in `rotated`. Crop back down to the original face box's
    // footprint from that center.
    final rcx = rotated.width / 2;
    final rcy = rotated.height / 2;
    final outW = box.width.clamp(1, rotated.width).toDouble();
    final outH = box.height.clamp(1, rotated.height).toDouble();
    final ox = (rcx - outW / 2).clamp(0, rotated.width - outW);
    final oy = (rcy - outH / 2).clamp(0, rotated.height - outH);
    return img.copyCrop(rotated,
        x: ox.toInt(), y: oy.toInt(), width: outW.toInt(), height: outH.toInt());
  }

  List<double> _runInference(Interpreter interpreter, img.Image face112) {
    // [1, 112, 112, 3] float32, normalized to roughly [-1, 1] — matches
    // this specific converted model's documented preprocessing (see
    // assets/models/README.md).
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(_inputSize, (x) {
          final pixel = face112.getPixel(x, y);
          return [
            (pixel.r - 127.5) / 128.0,
            (pixel.g - 127.5) / 128.0,
            (pixel.b - 127.5) / 128.0,
          ];
        }),
      ),
    );

    final output =
        List.generate(1, (_) => List.filled(_embeddingSize, 0.0));
    interpreter.run(input, output);
    return List<double>.from(output.first);
  }

  /// Component-wise mean of several same-length embeddings — averaging
  /// multiple good frames from one capture smooths out per-frame noise,
  /// the same reasoning [FaceGeometry.average] used to have for the old
  /// descriptor.
  static List<double> average(List<List<double>> vectors) {
    final len = vectors.first.length;
    final out = List<double>.filled(len, 0);
    for (final v in vectors) {
      for (var i = 0; i < len; i++) {
        out[i] += v[i];
      }
    }
    for (var i = 0; i < len; i++) {
      out[i] /= vectors.length;
    }
    return out;
  }

  /// Cosine of the angle between two embeddings — 1.0 means identical
  /// direction (same person), 0 unrelated, negative opposite. Scale-
  /// invariant by construction: dividing by both vectors' own norms
  /// cancels out magnitude entirely, so this compares correctly whether
  /// or not either embedding happens to be normalized — unlike a raw
  /// Euclidean distance, which a difference in *magnitude* alone (not
  /// identity) can throw off, since this model's training objective only
  /// ever makes a vector's *direction* meaningful. Returns -1.0 (lower
  /// than any real match can score) on a length mismatch — e.g. an old
  /// landmark-geometry vector left over from before this model existed —
  /// or a zero vector, rather than let either spuriously pass
  /// [matchThreshold].
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return -1.0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na < 1e-12 || nb < 1e-12) return -1.0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}
