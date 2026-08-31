import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'face_embedding_service.dart';

/// A collector account enrolled for face sign-in **on this device**.
/// Deliberately not synced to Firestore — biometric-derived data has no
/// business leaving the device it was captured on, and this app is
/// offline-first anyway, so device-local is the right scope, not a
/// limitation.
class FaceProfile {
  const FaceProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.password,
    required this.embedding,
  });

  final String uid;
  final String name;
  final String email;

  /// Stored so a face match can complete a real Firebase sign-in without a
  /// server component. Protected only by [FlutterSecureStorage]'s
  /// platform-backed encryption (Android Keystore / iOS Keychain) — see
  /// [FaceAuthService].
  final String password;
  final List<double> embedding;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'name': name,
        'email': email,
        'password': password,
        'embedding': embedding,
      };

  factory FaceProfile.fromJson(Map<String, dynamic> j) => FaceProfile(
        uid: j['uid'] as String,
        name: j['name'] as String,
        email: j['email'] as String,
        password: j['password'] as String,
        embedding: (j['embedding'] as List)
            .map((e) => (e as num).toDouble())
            .toList(),
      );
}

class FaceMatch {
  const FaceMatch(this.profile, this.similarity);
  final FaceProfile profile;

  /// Cosine similarity to the scanned face — see
  /// [FaceEmbeddingService.cosineSimilarity]/[matchThreshold]. Higher is
  /// closer; this is a similarity score, not a distance.
  final double similarity;
}

/// A collector's face embedding as synced to Firestore by a *different*
/// device (see YosRepository.syncFaceEmbedding) — read by
/// FaceLoginScreen's cloud fallback once no local [FaceProfile] on the
/// current phone matches. Deliberately carries no password: unlike a
/// local [FaceProfile] (whose cached password lets a match complete
/// sign-in immediately), a cloud match only identifies *who* a face might
/// be — actually signing in on this new device still needs that
/// collector's real password once, exactly like any other unfamiliar
/// device does today.
class CloudFaceProfile {
  const CloudFaceProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.embedding,
  });

  final String uid;
  final String name;
  final String email;
  final List<double> embedding;

  factory CloudFaceProfile.fromMap(Map<String, dynamic> d) => CloudFaceProfile(
        uid: d['uid'] as String,
        name: d['name'] as String,
        email: d['email'] as String,
        embedding: (d['embedding'] as List)
            .map((e) => (e as num).toDouble())
            .toList(),
      );
}

class CloudFaceMatch {
  const CloudFaceMatch(this.profile, this.similarity);
  final CloudFaceProfile profile;
  final double similarity;
}

/// Local store of face-enrolled collector accounts, plus matching.
///
/// Security model, spelled out because it's a real tradeoff: enrolling a
/// face on this device stores that collector's password here, encrypted at
/// rest by the OS keystore (via flutter_secure_storage) rather than by any
/// key this app manages itself. A face match only ever unlocks a credential
/// that was already saved to *this* device during a prior real sign-in — it
/// can't grant access to an account that hasn't been used here before, and
/// it never touches Firestore. The account's actual security boundary
/// remains the Firebase password.
class FaceAuthService {
  FaceAuthService._();
  static final FaceAuthService instance = FaceAuthService._();

  static const _storageKey = 'yos_face_profiles_v1';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<List<FaceProfile>> loadProfiles() async {
    final raw = await _storage.read(key: _storageKey);
    // Growable empty lists, not `const []` — callers like enroll() mutate
    // what this returns (removeWhere/add), and a const list throws
    // "Cannot remove from an unmodified list" the first time anyone
    // enrolls on a device with no prior Face ID data stored yet.
    if (raw == null || raw.isEmpty) return <FaceProfile>[];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => FaceProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt/unreadable — treat as no enrollments rather than crashing
      // the login screen.
      return <FaceProfile>[];
    }
  }

  Future<void> _saveAll(List<FaceProfile> profiles) => _storage.write(
        key: _storageKey,
        value: jsonEncode(profiles.map((p) => p.toJson()).toList()),
      );

  Future<bool> hasAnyProfile() async => (await loadProfiles()).isNotEmpty;

  /// Enrolls or re-enrolls [uid] on this device with a freshly captured
  /// descriptor, replacing any previous enrollment for the same account.
  Future<void> enroll({
    required String uid,
    required String name,
    required String email,
    required String password,
    required List<double> embedding,
  }) async {
    final profiles = await loadProfiles();
    profiles.removeWhere((p) => p.uid == uid);
    profiles.add(FaceProfile(
      uid: uid,
      name: name,
      email: email,
      password: password,
      embedding: embedding,
    ));
    await _saveAll(profiles);
  }

  /// Purges [uid]'s locally-enrolled profile from this device, if any —
  /// called when that account is removed (see YosRepository.
  /// deactivateCollector's callers) so a scan on *this* device can't keep
  /// matching a face whose account the app otherwise considers gone.
  /// This only ever reaches the device it's called on: profiles are
  /// deliberately never synced to Firestore (see class doc), so removing
  /// a collector from an admin's device can't reach into a *different*
  /// device where that same face might also be enrolled — bestMatch's
  /// live existence check is what actually closes that gap everywhere.
  Future<void> removeProfile(String uid) async {
    final profiles = await loadProfiles();
    final before = profiles.length;
    profiles.removeWhere((p) => p.uid == uid);
    if (profiles.length != before) await _saveAll(profiles);
  }

  /// Proactively checks every profile enrolled on this device against
  /// the cloud and purges any whose account no longer exists — called
  /// once when FaceLoginScreen opens, *before* any scan attempt runs, so
  /// a deleted account's face can never even be a candidate for a match,
  /// rather than only being caught reactively after it already won one
  /// (see FaceLoginScreen._afterLogin's own collectorExists check, which
  /// stays as the ultimate safety net regardless — that one runs after a
  /// real sign-in, which this can't do pre-auth).
  ///
  /// Uses face_profiles/{uid} (readable by any session, including the
  /// short-lived anonymous one this signs in with) as the existence
  /// signal rather than collectors/{uid} directly: firestore.rules only
  /// lets a caller read their *own* collectors/{uid} doc or an admin
  /// read anyone's, neither of which is available pre-sign-in. Since
  /// enrollment always writes both docs together (see
  /// FaceEnrollScreen._save / YosRepository.resetCollectorPassword) and
  /// deactivateCollector always deletes both together, a missing
  /// face_profiles/{uid} for a locally-cached uid is a reliable signal
  /// that account is gone.
  ///
  /// Silently does nothing on any failure (offline, Anonymous sign-in
  /// not enabled, etc.) — pruning is a nice-to-have hardening pass, not
  /// something that should ever block or break Face ID sign-in.
  Future<void> pruneStaleProfiles() async {
    try {
      final local = await loadProfiles();
      if (local.isEmpty) return;

      await FirebaseAuth.instance.signInAnonymously();
      final cloud = await FirebaseFirestore.instance
          .collection('face_profiles')
          .get();
      await FirebaseAuth.instance.signOut();

      final liveUids = cloud.docs.map((d) => d.id).toSet();
      final stale = local.where((p) => !liveUids.contains(p.uid)).toList();
      for (final p in stale) {
        await removeProfile(p.uid);
      }
    } catch (_) {
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
    }
  }

  /// Closest (highest cosine similarity, see
  /// [FaceEmbeddingService.cosineSimilarity]) enrolled profile at or
  /// above [FaceEmbeddingService.matchThreshold], or null if nothing on
  /// this device is close enough. A profile enrolled under the old
  /// landmark-geometry descriptor (different vector length) simply never
  /// matches here, so it needs re-enrollment after this upgrade, rather
  /// than silently comparing incompatible descriptors.
  FaceMatch? bestMatch(List<double> embedding, List<FaceProfile> profiles) {
    FaceMatch? best;
    for (final p in profiles) {
      final s = FaceEmbeddingService.cosineSimilarity(embedding, p.embedding);
      if (s >= FaceEmbeddingService.matchThreshold &&
          (best == null || s > best.similarity)) {
        best = FaceMatch(p, s);
      }
    }
    return best;
  }

  /// Same matching rule as [bestMatch] (highest cosine similarity at or
  /// above [FaceEmbeddingService.matchThreshold]), run against
  /// cloud-synced profiles from a *different* device instead of this
  /// one's local store — see FaceLoginScreen's cloud fallback, which only
  /// calls this once [bestMatch] against local profiles found nothing.
  CloudFaceMatch? bestCloudMatch(
      List<double> embedding, List<CloudFaceProfile> profiles) {
    CloudFaceMatch? best;
    for (final p in profiles) {
      final s = FaceEmbeddingService.cosineSimilarity(embedding, p.embedding);
      if (s >= FaceEmbeddingService.matchThreshold &&
          (best == null || s > best.similarity)) {
        best = CloudFaceMatch(p, s);
      }
    }
    return best;
  }

  /// Diagnostic only: the highest similarity to any enrolled profile,
  /// regardless of [FaceEmbeddingService.matchThreshold] — [bestMatch]
  /// only ever reports a score for a profile that already passed the
  /// threshold, which makes it impossible to tell "correctly rejected,
  /// comfortably" apart from "rejected by a hair" or "threshold is too
  /// strict" from the UI alone. Callers can log/display this to tune
  /// [FaceEmbeddingService.matchThreshold] against real captures.
  double? closestSimilarity(List<double> embedding, List<FaceProfile> profiles) {
    double? max;
    for (final p in profiles) {
      final s = FaceEmbeddingService.cosineSimilarity(embedding, p.embedding);
      if (max == null || s > max) max = s;
    }
    return max;
  }
}
