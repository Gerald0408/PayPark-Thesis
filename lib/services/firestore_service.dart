import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/username.dart';
import '../models/access_request.dart';
import '../models/collector.dart';
import '../models/trashed_collector.dart';
import '../core/names.dart';
import '../core/parking_fee.dart';
import '../models/transaction.dart';
import 'face_auth_service.dart';
import 'fee_settings_service.dart';

/// Central data layer. Firestore's built-in offline persistence gives us:
///  - full offline logging (writes land in local cache instantly),
///  - automatic background sync once connectivity returns,
///  - `metadata.hasPendingWrites` to render "Pending Sync" badges.
class YosRepository extends ChangeNotifier {
  YosRepository._();
  static final YosRepository instance = YosRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final Uuid _uuid = const Uuid();

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _online = true;
  bool get online => _online;

  String get _uid => _auth.currentUser?.uid ?? 'unknown';

  /// Signed-in collector's display name, for attributing a receipt to
  /// whoever actually printed it — same fallback RootShell/
  /// PasswordLoginScreen already use when Firebase Auth has no display
  /// name set for this account.
  String get currentUserName {
    final name = _auth.currentUser?.displayName;
    return name != null && name.trim().isNotEmpty
        ? formatPersonName(name)
        : 'Collector';
  }

  /// Signed-in collector's own phone number, for the receipt footer (see
  /// ReceiptPreviewDrawer._receiptClosingLines) — unlike [currentUserName],
  /// this isn't cached on the Firebase Auth user itself, only in their
  /// collectors/{uid} doc, so it's a real Firestore read rather than a
  /// synchronous getter. Null if signed out, the doc has no phone (an
  /// account registered before that field existed), or the read fails.
  Future<String?> currentUserPhone() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    try {
      final doc = await _collectors.doc(uid).get();
      final phone = (doc.data() as Map<String, dynamic>?)?['phone'];
      return phone is String && phone.isNotEmpty ? phone : null;
    } catch (_) {
      return null;
    }
  }

  CollectionReference get _tx => _db.collection('transactions');
  CollectionReference get _audit => _db.collection('audit_logs');
  CollectionReference get _collectors => _db.collection('collectors');
  CollectionReference get _trashedCollectors =>
      _db.collection('trashed_collectors');
  CollectionReference get _faceProfiles => _db.collection('face_profiles');

  /// Call once after Firebase.initializeApp().
  Future<void> init() async {
    if (kIsWeb) {
      try {
        await _db.enablePersistence(
            const PersistenceSettings(synchronizeTabs: true));
      } catch (_) {
        // Persistence unavailable (e.g. multiple tabs) ï¿½ continue online-only.
      }
    } else {
      _db.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
    }
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final nowOnline = results.any((r) => r != ConnectivityResult.none);
      if (nowOnline != _online) {
        _online = nowOnline;
        notifyListeners();
        // Fire-and-forget: sync state changes are themselves audited.
        logAudit(
          nowOnline ? AuditAction.syncOnline : AuditAction.syncOffline,
          nowOnline
              ? 'Connection Restored Background Sync Resumed'
              : 'Connection Lost Entering Offline Logging Mode',
        );
      }
    });
    final first = await Connectivity().checkConnectivity();
    _online = first.any((r) => r != ConnectivityResult.none);
    notifyListeners();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------- AUTH ----

  Future<UserCredential> login(String email, String password) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
          email: email, password: password);
      // Same permission-denied race as markFaceIdEnrolled above: a fresh
      // sign-in's audit write can transiently fail server-side auth
      // recognition. The audit entry is best-effort — never let it turn a
      // real, successful sign-in into a reported failure.
      try {
        await logAudit(AuditAction.login, 'Collector Signed In');
      } catch (_) {}
      return cred;
    } on FirebaseAuthException {
      // Failed attempts are audited without storing the attempted
      // password — best-effort only: firestore.rules requires
      // request.auth != null to write audit_logs, and at this exact
      // point sign-in just failed, so there is no session. That write
      // throwing its own PERMISSION_DENIED must never replace the real
      // FirebaseAuthException below with a confusing Firestore one — the
      // caller's `on FirebaseAuthException` handling (specific messages
      // for wrong-password, user-not-found, etc.) depends on the
      // original exception actually reaching it.
      try {
        await _audit.add(AuditLog(
          logId: _uuid.v4(),
          actorId: email,
          actionType: AuditAction.loginFailed,
          description: 'Failed login attempt',
          timestamp: DateTime.now(),
        ).toMap());
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> logout() async {
    await logAudit(AuditAction.logout, 'Collector Signed Out');
    await _auth.signOut();
  }

  /// Firebase Auth has no native "username + password" sign-in — only
  /// email+password. This app wants a username as the account handle, so
  /// every account's actual Firebase email is a deterministic, never-shown
  /// synthetic address derived from it. [register] and [login] both funnel
  /// through this so a collector never has to know it exists. Delegates to
  /// core/username.dart, which also holds the matching normalization.
  static String emailForUsername(String username) =>
      syntheticEmailForUsername(username);

  /// Creates the Firebase Auth account for [username] with the collector's
  /// own [password], then finishes registration exactly as
  /// [completeRegistration] describes. Uniqueness is enforced by Firebase
  /// Auth itself: two collectors picking the same username collide on the
  /// same synthetic email and the second create throws
  /// email-already-in-use.
  ///
  /// [wantsAdmin] has no UI to set it true anymore — RegisterScreen always
  /// passes false, since Admin is meant to be a single, pre-seeded built-in
  /// account rather than something self-registration grants. It stays a
  /// parameter (rather than being deleted) because it's still how that one
  /// built-in account actually gets provisioned — see
  /// [completeRegistration] for what happens when it's true. Returns the
  /// new credential alongside whether admin was actually granted, since a
  /// granted [wantsAdmin] doesn't always mean the account came out admin.
  Future<({UserCredential cred, bool isAdmin})> register({
    required String name,
    required String username,
    required String password,
    required String phone,
    required DateTime birthday,
    required bool wantsAdmin,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: emailForUsername(username),
      password: password,
    );
    final isAdmin = await completeRegistration(
        name: name,
        username: username,
        phone: phone,
        birthday: birthday,
        wantsAdmin: wantsAdmin);
    return (cred: cred, isAdmin: isAdmin);
  }

  /// Fire-and-forget "please help me back in" ping for a collector who's
  /// locked out on a new/reinstalled device — there's no self-service
  /// phone/OTP path anymore (accounts aren't tied to a phone number), so
  /// this just leaves a pending request for the admin to see (see
  /// [pendingAccessRequests]) and act on using real-world knowledge of who
  /// their collectors are — typically by finding the matching account in
  /// CollectorsScreen and deactivating it so the collector can register
  /// again. Deliberately allowed while signed out (see firestore.rules) —
  /// a locked-out collector is, by definition, not authenticated.
  Future<String> requestAccessReset(String name) async {
    final ref = await _db.collection('access_requests').add({
      'name': name.trim(),
      'requested_at': Timestamp.now(),
      'status': 'pending',
    });
    return ref.id;
  }

  /// Admin-only live list of outstanding access requests, newest first.
  /// Sorted client-side rather than via Firestore's own orderBy — a
  /// `where` filter combined with an `orderBy` on a *different* field
  /// requires a composite index, which this deployment doesn't have (and
  /// doesn't need one just for this: request volume is small enough that
  /// sorting the already-filtered results locally is simpler than managing
  /// firestore.indexes.json and waiting for an index build).
  Stream<List<AccessRequest>> pendingAccessRequests() => _db
      .collection('access_requests')
      .where('status', isEqualTo: 'pending')
      .snapshots()
      .map((s) => s.docs.map(AccessRequest.fromDoc).toList()
        ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt)));

  /// Live view of one specific request by ID — what the collector's own
  /// AccessRequestScreen watches while waiting, since [pendingAccessRequests]
  /// itself is admin-only (see firestore.rules' access_requests/{id}
  /// get-vs-list split). Once [resolveAccessRequest] sets a
  /// [AccessRequest.newUsername], this is how the waiting screen learns
  /// which account to offer a passcode field for.
  Stream<AccessRequest?> watchAccessRequest(String id) => _db
      .collection('access_requests')
      .doc(id)
      .snapshots()
      .map((d) => d.exists ? AccessRequest.fromDoc(d) : null);

  /// Marks a request handled once the admin has actually dealt with it.
  /// [newUsername], when given, is the brand-new account
  /// resetCollectorPassword just created for this collector — stored here
  /// so their own waiting screen can pick it up and offer a passcode
  /// field, without ever storing the passcode itself (that's told to them
  /// out-of-band by the admin, same as always).
  Future<void> resolveAccessRequest(String requestId,
      {String? newUsername}) async {
    await _db.collection('access_requests').doc(requestId).update({
      'status': 'resolved',
      if (newUsername != null) 'new_username': newUsername,
    });
    await logAudit(
        AuditAction.accessRequestResolved, 'Resolved an access request');
  }

  /// Finishes self-service collector sign-up: call once [register] has
  /// already created + signed in the Firebase Auth account. Writes the
  /// matching `collectors/{uid}` doc — its existence is what
  /// firestore.rules checks to authorize a collector, see isCollector()
  /// there — so a verified account can read/write transactions
  /// immediately, no separate admin-approval step.
  ///
  /// Admin status is decided here too, from [wantsAdmin] — but only the
  /// *first* registration that asks for it actually gets it.
  /// `meta/admin_bootstrap` is a one-time sentinel
  /// doc: the transaction only grants admin if [wantsAdmin] is true AND
  /// that sentinel doesn't exist yet, claiming it atomically in the same
  /// commit, so two people registering as Admin at the same moment can't
  /// both end up admin (Firestore's optimistic concurrency retries
  /// whichever transaction loses the race, and it'll see the sentinel
  /// already claimed on retry — landing that collector as a plain,
  /// non-admin account instead, which is why this returns whether admin
  /// was actually granted rather than assuming [wantsAdmin] succeeded).
  /// firestore.rules enforces the same sentinel invariant server-side —
  /// see isAdmin()/collectors there — so this isn't just a client-side
  /// courtesy.
  Future<bool> completeRegistration({
    required String name,
    required String username,
    required String phone,
    required DateTime birthday,
    required bool wantsAdmin,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('completeRegistration called while signed out');
    }
    await user.updateDisplayName(name);
    final uid = user.uid;
    final bootstrapRef = _db.collection('meta').doc('admin_bootstrap');

    // Same fresh-sign-in permission race as markFaceIdEnrolled /
    // isCurrentUserFaceIdEnrolled below — this transaction is the very
    // first Firestore call after createUserWithEmailAndPassword just
    // minted a brand-new auth token, so it's the single likeliest place to
    // hit it. Retry with backoff rather than surfacing a transient
    // permission-denied as "registration failed" for an account that was
    // actually created fine.
    bool isAdmin = false;
    for (var attempt = 0;; attempt++) {
      try {
        isAdmin = await _db.runTransaction<bool>((tx) async {
          final bootstrap = await tx.get(bootstrapRef);
          final admin = wantsAdmin && !bootstrap.exists;
          if (admin) {
            tx.set(bootstrapRef, {'admin_uid': uid});
          }
          tx.set(_collectors.doc(uid), {
            'name': name,
            'username': username,
            'phone': phone,
            'birthday': Timestamp.fromDate(birthday),
            'created_at': Timestamp.now(),
            'is_admin': admin,
            'face_id_enrolled': false,
          });
          return admin;
        });
        break;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied' || attempt >= 2) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }

    await logAudit(AuditAction.register,
        isAdmin ? 'Collector registered (admin)' : 'Collector registered');
    return isAdmin;
  }

  /// Whether the currently signed-in account has completed the mandatory
  /// Face ID gate — one-shot check for a route guard (see RootShell),
  /// not a rebuilding widget, where a stream would be the right tool
  /// instead.
  Future<bool> isCurrentUserFaceIdEnrolled() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return false;
    // Same fresh-sign-in permission race as markFaceIdEnrolled — a read
    // dispatched right after sign-in can transiently see the token as not
    // yet recognized. Retry rather than let the route guard hang or
    // wrongly bounce a fully-enrolled account back to the password gate.
    for (var attempt = 0;; attempt++) {
      try {
        final doc = await _collectors.doc(uid).get();
        return (doc.data() as Map<String, dynamic>?)?['face_id_enrolled'] ==
            true;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied' || attempt >= 2) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }
  }

  /// Marks the mandatory Face ID gate satisfied for the currently
  /// signed-in account — call once a real on-device enrollment actually
  /// succeeds (see FaceEnrollScreen._save), never speculatively. One-way:
  /// firestore.rules only allows this field false-or-missing → true, never
  /// back, so losing the local enrollment can't silently reopen the gate
  /// on its own — re-enrolling just sets the same field to the same value.
  Future<void> markFaceIdEnrolled() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('markFaceIdEnrolled called while signed out');
    }
    // A write dispatched right after a fresh sign-in can occasionally race
    // Firestore's server-side recognition of the just-minted auth token and
    // come back permission-denied even though the rule itself would allow
    // it a moment later — retry with backoff rather than surfacing that as
    // a real failure.
    for (var attempt = 0;; attempt++) {
      try {
        await _collectors.doc(uid).update({'face_id_enrolled': true});
        return;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied' || attempt >= 2) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }
  }

  /// Self-service edit of the signed-in collector's own name/phone/
  /// birthday — for ProfileScreen's own "Edit" flow. Deliberately narrower
  /// than admin's CollectorsScreen actions: no username, role, or account
  /// recovery here, just the plain details captured at registration (see
  /// firestore.rules' collectors/{uid} update rule for the matching
  /// self-serve branch that only allows exactly these three fields).
  Future<void> updateOwnProfile({
    required String name,
    String? phone,
    DateTime? birthday,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('updateOwnProfile called while signed out');
    }
    await _collectors.doc(uid).update({
      'name': name,
      'phone': phone,
      'birthday': birthday == null ? null : Timestamp.fromDate(birthday),
    });
  }

  /// Self-service profile photo update — its own single-field write,
  /// separate from [updateOwnProfile], since ProfileScreen applies a new
  /// photo immediately on pick rather than bundling it into that form's
  /// Save changes / Cancel flow (see firestore.rules' matching photo_url
  /// self-serve branch).
  Future<void> updateOwnPhotoUrl(String url) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('updateOwnPhotoUrl called while signed out');
    }
    await _collectors.doc(uid).update({'photo_url': url});
  }

  /// Live admin status of whoever's currently signed in — false while
  /// signed out or before the collectors/{uid} doc has loaded.
  ///
  /// Deliberately a getter that returns a fresh Stream each call, NOT a
  /// single cached/shared one: a shared broadcast stream only delivers
  /// Firestore's "current value" to whichever listener subscribes first —
  /// a screen that starts listening later (e.g. opening FeesScreen after
  /// the dashboard's already subscribed) would never get an initial value
  /// at all. Each caller is expected to grab its own instance ONCE (e.g.
  /// a `late final` field on a State, or a one-time `.listen()` in
  /// initState) rather than re-reading this getter on every rebuild —
  /// re-reading it inside a StreamBuilder's `build()` is what caused the
  /// "_dependents.isEmpty" crash previously, since that handed
  /// StreamBuilder a new stream instance every rebuild.
  Stream<bool> get currentUserIsAdmin =>
      _auth.authStateChanges().asyncExpand((user) {
        if (user == null) return Stream.value(false);
        return _collectors.doc(user.uid).snapshots().map(
            (d) => (d.data() as Map<String, dynamic>?)?['is_admin'] == true);
      });

  /// Live view of whoever's currently signed in as a full [Collector] —
  /// the same name/username/role/registered-date captured at registration
  /// — for ProfileScreen's account details card. Null while signed out or
  /// before the collectors/{uid} doc has loaded. Same "fresh Stream per
  /// call, cache it yourself" contract as [currentUserIsAdmin] above.
  Stream<Collector?> get currentCollectorProfile =>
      _auth.authStateChanges().asyncExpand((user) {
        if (user == null) return Stream.value(null);
        return _collectors
            .doc(user.uid)
            .snapshots()
            .map((d) => d.exists ? Collector.fromDoc(d) : null);
      });

  /// One-shot admin check for the currently signed-in user — for gating a
  /// single action rather than driving a rebuilding widget, where
  /// [currentUserIsAdmin]'s long-lived stream is the right tool instead.
  Future<bool> isCurrentUserAdmin() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return false;
    final doc = await _collectors.doc(uid).get();
    return (doc.data() as Map<String, dynamic>?)?['is_admin'] == true;
  }

  // --------------------------------------------------------- FACE SYNC ----

  /// Uploads this device's freshly-captured face embedding to the shared
  /// `face_profiles/{uid}` directory, so a *different* phone can later
  /// recognize the same collector (see FaceLoginScreen._tryCloudMatch)
  /// instead of needing its own separate enrollment. Never includes the
  /// account's password — a cloud match only identifies who a face might
  /// be; completing an actual sign-in from it still needs that
  /// collector's real password once on the new device (see
  /// FaceEnrollScreen._save, which calls this right after the local,
  /// password-bearing FaceAuthService.enroll succeeds).
  Future<void> syncFaceEmbedding({
    required String uid,
    required String name,
    required String email,
    required List<double> embedding,
  }) async {
    await _faceProfiles.doc(uid).set({
      'uid': uid,
      'name': name,
      'email': email,
      'embedding': embedding,
      'updated_at': Timestamp.now(),
    });
  }

  /// Every collector's cloud-synced face profile — read by
  /// FaceLoginScreen only once no *local* match exists on the current
  /// phone. Requires at least an anonymous session per firestore.rules
  /// (there's no real sign-in yet at the point this runs on an unfamiliar
  /// device).
  Future<List<CloudFaceProfile>> fetchCloudFaceProfiles() async {
    final snap = await _faceProfiles.get();
    return snap.docs
        .map((d) => CloudFaceProfile.fromMap(d.data() as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------------ ADMIN ----

  /// All registered collectors — admin-only per firestore.rules (a
  /// non-admin's read is denied server-side, this doesn't gate anything
  /// client-side).
  Stream<List<Collector>> allCollectors() => _collectors
      .orderBy('created_at', descending: true)
      .snapshots()
      .map((s) => s.docs.map(Collector.fromDoc).toList());

  /// Deactivates a collector by moving their collectors/{uid} doc into
  /// trashed_collectors/{uid} — with no Cloud Functions or admin email to
  /// run a real password reset, this is the practical stand-in: a
  /// locked-out collector (see requestAccessReset) gets deactivated here,
  /// then either re-registers clean with a new username and password, or
  /// an admin restores this same doc from the trash bin (see
  /// [restoreCollector]) if the removal was a mistake. Their Firebase Auth
  /// account itself isn't deleted (would need Admin SDK) — it's exactly
  /// this collectors/{uid} doc's absence that fails isCollector() in
  /// firestore.rules, so it's a real deactivation from the app's
  /// perspective either way, trashed or gone for good.
  Future<void> deactivateCollector(String uid, String name) async {
    final snap = await _collectors.doc(uid).get();
    final data = snap.data();
    if (data is Map<String, dynamic>) {
      await _trashedCollectors.doc(uid).set({
        ...data,
        'deactivated_at': Timestamp.now(),
        'deactivated_by': currentUserName,
      });
    }
    await _collectors.doc(uid).delete();
    // Best-effort: a removed collector's cloud-synced face (see
    // syncFaceEmbedding) must not keep surfacing as a valid cloud match
    // on some other phone, but this cleanup failing is never worse than
    // the deactivation itself — FaceLoginScreen's own collectorExists
    // check still catches a stale match afterward regardless.
    try {
      await _faceProfiles.doc(uid).delete();
    } catch (_) {}
    // Best-effort, same-device cleanup: only reaches a locally-enrolled
    // profile for uid if it happens to live on *this* device (e.g. the
    // admin's own phone was also where this collector once enrolled) —
    // FaceLoginScreen's own live collectorExists check is what actually
    // closes this everywhere else.
    try {
      await FaceAuthService.instance.removeProfile(uid);
    } catch (_) {}
    await logAudit(AuditAction.deactivateCollector, 'Deactivated $name');
  }

  /// All trashed (deactivated) collectors — admin-only per
  /// firestore.rules, same shape as [allCollectors].
  Stream<List<TrashedCollector>> trashedCollectors() => _trashedCollectors
      .orderBy('deactivated_at', descending: true)
      .snapshots()
      .map((s) => s.docs.map(TrashedCollector.fromDoc).toList());

  /// Undoes [deactivateCollector]: recreates collectors/{uid} from the
  /// trashed doc's own fields (so a collector who was removed by mistake
  /// doesn't have to re-register from scratch) and removes it from the
  /// trash bin. Works because the account's underlying Firebase Auth
  /// credential was never deleted in the first place — only this doc's
  /// absence ever locked them out, so recreating it with the same uid is
  /// enough to pass isCollector() again.
  Future<void> restoreCollector(String uid, String name) async {
    final snap = await _trashedCollectors.doc(uid).get();
    final data = snap.data();
    if (data is! Map<String, dynamic>) {
      throw StateError('$name is no longer in the trash bin.');
    }
    final restored = Map<String, dynamic>.from(data)
      ..remove('deactivated_at')
      ..remove('deactivated_by');
    await _collectors.doc(uid).set(restored);
    await _trashedCollectors.doc(uid).delete();
    await logAudit(AuditAction.restoreCollector, 'Restored $name');
  }

  /// Permanently removes a trashed collector — the trash bin's own
  /// "empty forever" action, once an admin is sure the account should
  /// never come back. Only the trash doc itself is touched; their past
  /// transactions and audit history (separate collections) are untouched,
  /// same as a plain [deactivateCollector].
  Future<void> permanentlyDeleteCollector(String uid, String name) async {
    await _trashedCollectors.doc(uid).delete();
    await logAudit(
        AuditAction.permanentlyDeleteCollector, 'Permanently deleted $name');
  }

  /// Lets the ADMIN reset a locked-out collector's access from the
  /// admin's own device/session — the admin picks a new username and a
  /// passcode for them, and this creates a fresh Firebase Auth account +
  /// collectors/{uid} doc with that credential, deactivating the old one
  /// (see [deactivateCollector]) the same way a self-service re-register
  /// always has.
  ///
  /// Firebase Auth's client SDK has no "create an account for someone
  /// else" primitive: calling createUserWithEmailAndPassword on the
  /// normal, shared [FirebaseAuth] instance immediately signs *that*
  /// session in as the brand-new account — which would kick the admin
  /// out of their own session mid-action. A second, throwaway
  /// [FirebaseApp] instance (same project, fully isolated auth state) is
  /// the standard workaround: the new account is created and signed into
  /// *that* instance instead, so [FirebaseAuth.instance] (and the
  /// admin's own session on it) never changes. Signed out of once this
  /// finishes, win or lose — see below for why it's never `.delete()`d.
  ///
  /// The old account's Firebase Auth credential itself isn't deleted (no
  /// Cloud Functions/Admin SDK access to do that from the client) — only
  /// its collectors/{uid} doc is, which is enough to lock it out
  /// (isCollector() fails without that doc) while its Face ID/audit
  /// history under the old uid stays as a historical record.
  ///
  /// The secondary [FirebaseApp] itself is deliberately never torn down
  /// with `.delete()` afterward, signOut() only — cloud_firestore's native
  /// Android/iOS SDKs share a single underlying gRPC/worker layer across
  /// every FirebaseApp in the process, and deleting *any* app instance
  /// briefly disrupts *all* of them, not just the one being deleted. In
  /// this app that means every other live Firestore listener at that
  /// moment — CollectorsScreen's own allCollectors() stream (open the
  /// whole time an admin is on this exact screen), FeeSettingsService,
  /// PointsSettingsService, whatever else happens to be listening — can
  /// throw a stray "[cloud_firestore/unknown] FirebaseApp was deleted"
  /// right as this finishes, which used to surface as a bogus "Couldn't
  /// reset access" error even though the reset itself had already
  /// succeeded. A leftover signed-out secondary FirebaseApp with no
  /// active listeners costs a few negligible dart/native objects for the
  /// rest of the process's lifetime — trivial next to breaking every
  /// other Firestore stream in the app on every single password reset.
  Future<void> resetCollectorPassword({
    required String oldUid,
    required String oldName,
    required String name,
    required String username,
    required String phone,
    required DateTime birthday,
    required String password,
  }) async {
    final secondaryApp = await Firebase.initializeApp(
      name: 'password_reset_${DateTime.now().microsecondsSinceEpoch}',
      options: Firebase.app().options,
    );
    final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
    final secondaryDb = FirebaseFirestore.instanceFor(app: secondaryApp);
    try {
      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: emailForUsername(username),
        password: password,
      );
      final user = cred.user!;
      await user.updateDisplayName(name);
      await secondaryDb.collection('collectors').doc(user.uid).set({
        'name': name,
        'username': username,
        'phone': phone,
        'birthday': Timestamp.fromDate(birthday),
        'created_at': Timestamp.now(),
        'is_admin': false,
        'face_id_enrolled': false,
      });
    } finally {
      // Best-effort sign-out only — see the doc comment above for why
      // this deliberately stops short of secondaryApp.delete().
      try {
        await secondaryAuth.signOut();
      } catch (_) {}
    }

    // Best-effort: the new account above already works regardless of
    // whether this succeeds, so a failure here doesn't undo the reset —
    // it just leaves the old, now-redundant account technically still
    // active alongside the new one.
    try {
      await deactivateCollector(oldUid, oldName);
    } catch (_) {}

    await logAudit(AuditAction.passwordReset,
        'Reset access for $oldName as new collector "$username"');
  }

  /// Whether [uid] still has a collectors/{uid} doc — the live check
  /// FaceLoginScreen runs on a candidate face match before trusting it.
  /// A locally-enrolled face profile (see FaceAuthService) is never
  /// synced to Firestore and never cleaned up automatically when its
  /// account is deactivated on some *other* device, so without this a
  /// removed collector's face could keep signing back into an account
  /// the app otherwise considers gone, on any device that still carries
  /// the stale profile.
  ///
  /// Forces `Source.server` rather than the default cache-or-server
  /// behavior — this app runs Firestore with unlimited offline
  /// persistence (see init() above), so a plain `.get()` can silently
  /// return a *stale locally-cached* copy of this doc instead of ever
  /// reaching the server, if this device hasn't synced since the account
  /// was deactivated elsewhere. That let a genuinely-deleted collector's
  /// face keep signing in and landing on "Welcome back" as long as their
  /// device's local cache hadn't caught up with the deletion yet. Safe to
  /// force server-only here specifically: this call only ever runs right
  /// after [login]'s own signInWithEmailAndPassword just succeeded, which
  /// already required a real network round-trip a moment ago — there's
  /// no meaningful offline case to preserve for this one check.
  Future<bool> collectorExists(String uid) async {
    // Same fresh-sign-in permission race as markFaceIdEnrolled /
    // isCurrentUserFaceIdEnrolled above — this read is dispatched right
    // after login() just minted a brand-new auth token (see
    // FaceLoginScreen._afterLogin, which calls this immediately after a
    // successful sign-in), so it's exactly the kind of read that can
    // transiently see the token as not yet recognized server-side.
    // Retry rather than let an unrelated permission-denied blip get
    // mistaken for "this account was removed."
    for (var attempt = 0;; attempt++) {
      try {
        final doc = await _collectors
            .doc(uid)
            .get(const GetOptions(source: Source.server));
        return doc.exists;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied' || attempt >= 2) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }
  }

  /// Promotes [uid] to Admin, or demotes them back to Collector — the
  /// in-app alternative to a one-off Firebase Console edit, so an admin
  /// can hand off or share admin access without ever leaving the app.
  ///
  /// Deliberately can't target the caller's own doc — see firestore.rules'
  /// collectors/{uid} update rule, which requires `request.auth.uid !=
  /// uid` for this exact write. No single admin can strip their own
  /// access this way, so a full handoff always takes two steps (promote
  /// the new admin, then have *them* demote you) — which guarantees the
  /// app can never end up with zero admins from an in-app action alone.
  Future<void> setAdminRole({
    required String uid,
    required String name,
    required bool makeAdmin,
  }) async {
    await _collectors.doc(uid).update({'is_admin': makeAdmin});
    await logAudit(
      makeAdmin ? AuditAction.adminPromoted : AuditAction.adminDemoted,
      makeAdmin ? 'Made $name an Admin' : 'Removed Admin access from $name',
    );
  }

  // -------------------------------------------------------- TRANSACTIONS ----

  /// Generates tracking IDs like `POB-20260721-8F3A2C`.
  String _newTrackingId(DateTime ts) {
    final date = DateFormat('yyyyMMdd').format(ts);
    final suffix = _uuid.v4().substring(0, 6).toUpperCase();
    return 'POB-$date-$suffix';
  }

  /// Builds a transaction record for the receipt preview — no Firestore
  /// write. The collector hasn't committed to logging anything yet at
  /// this point; only [saveTransaction] actually persists it, once they
  /// print or explicitly save without printing.
  ParkingTransaction buildTransaction({
    required String driverName,
    required String plateNumber,
    required VehicleType type,
    required String zoneId,
    String source = EntrySource.manual,
  }) {
    final ts = DateTime.now();
    return ParkingTransaction(
      trackingId: _newTrackingId(ts),
      driverName: driverName.trim(),
      plateNumber: plateNumber.trim().toUpperCase(),
      vehicleType: type.label,
      fee: FeeSettingsService.instance.feeFor(type),
      zoneId: zoneId,
      timestamp: ts,
      collectorId: _auth.currentUser?.uid,
      collectorName: currentUserName,
      source: source,
    );
  }

  /// Instant, offline-safe write — the actual commit for a transaction
  /// already built by [buildTransaction]. [tx.printed] should already
  /// reflect the outcome (true if this is being saved right after a
  /// successful print) so there's no separate "mark as printed" update
  /// needed afterward.
  void saveTransaction(ParkingTransaction tx) {
    // Deliberately NOT awaited: Firestore caches locally and syncs later.
    _tx.add(tx.toMap());
    if (tx.totalPaid == 0) {
      logAudit(AuditAction.newEntry,
          'Time In ${tx.vehicleType} ${tx.plateNumber} at '
          '${DateFormat('MMM d hh:mm a').format(tx.timestamp)} (${tx.trackingId})');
    } else {
      logAudit(AuditAction.newEntry,
          'Logged ${tx.vehicleType} ${tx.plateNumber} PHP '
          '${tx.totalPaid.toStringAsFixed(2)} via ${PaymentMethod.label(tx.paymentMethod)}'
          '${tx.paymentRef != null ? ' (ref ${tx.paymentRef})' : ''} '
          '(${tx.trackingId})');
    }
    if (tx.printed) {
      logAudit(AuditAction.printReceipt,
          '${tx.totalPaid == 0 ? 'Printed time-in ticket' : 'Printed receipt'} ${tx.trackingId}');
    }
  }

  /// The vehicle's current visit if it's still parked — its most recent
  /// transaction with no time out, from the last 24 hours (an older open
  /// one is a forgotten check-out, not a car still in the lot). Null when
  /// it isn't checked in. Two equality filters, so Firestore serves this
  /// without a composite index; works offline from the local cache.
  Future<ParkingTransaction?> openVisitFor(String plateNumber) async {
    final snap = await _tx
        .where('plate_number', isEqualTo: plateNumber.trim().toUpperCase())
        .where('time_out', isNull: true)
        .get();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final open = snap.docs
        .map(ParkingTransaction.fromDoc)
        .where((tx) => tx.awaitingCheckout && tx.timestamp.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return open.firstOrNull;
  }

  /// Time out: records when the vehicle left and everything paid now —
  /// offline-safe, returns the updated transaction for the receipt.
  ///
  /// [price] is the whole visit (FeeSettingsService.quote). A time-in
  /// ticket (nothing paid yet) gets the base fee, extra hours, any
  /// lost-ticket fee and points discount written in full. A visit from
  /// before time-in tickets existed already paid its base fee at check-in,
  /// so only the remainder is collected, as extra.
  ParkingTransaction checkOut(
    ParkingTransaction tx, {
    required ParkingFee price,
    required String paymentMethod,
    String? paymentRef,
    DateTime? timeOut,
  }) {
    final out = timeOut ?? DateTime.now();
    final name = currentUserName;
    final ref = paymentRef == null || paymentRef.isEmpty ? null : paymentRef;
    final prepaid = tx.fee > 0;
    final baseCharged =
        (price.baseFee - price.discount).clamp(0, price.baseFee).toDouble();
    final extra = prepaid
        ? (price.total - tx.fee - price.lostTicketFee).clamp(0, double.infinity)
            .toDouble()
        : price.extraFee;

    _tx.doc(tx.docId).update({
      'time_out': Timestamp.fromDate(out),
      'checked_out_by': _uid,
      'checked_out_by_name': name,
      if (!prepaid) ...{
        'fee': baseCharged,
        'payment_method': paymentMethod,
        if (ref != null) 'payment_ref': ref,
        if (price.discount > 0) 'discount': price.discount,
        'printed': true,
      },
      if (extra > 0) ...{
        'extra_hours': price.extraHours,
        'extra_fee': extra,
        'extra_payment_method': paymentMethod,
        if (ref != null) 'extra_payment_ref': ref,
      },
      if (price.lostTicketFee > 0) 'lost_ticket_fee': price.lostTicketFee,
    });
    logAudit(
        AuditAction.checkOut,
        'Time Out ${tx.plateNumber} (${tx.trackingId}) at '
        '${DateFormat('MMM d hh:mm a').format(out)}'
        '${timeOut != null ? ' (time chosen by collector)' : ''}, '
        'stayed ${formatStay(out.difference(tx.timestamp))}, '
        'paid PHP ${(prepaid ? extra + price.lostTicketFee : price.total).toStringAsFixed(2)} '
        'via ${PaymentMethod.label(paymentMethod)}'
        '${ref != null ? ' (ref $ref)' : ''}'
        '${price.lostTicketFee > 0 ? ', incl. lost ticket fee' : ''}');
    return tx.copyWith(
      timeOut: out,
      checkedOutByName: name,
      fee: prepaid ? tx.fee : baseCharged,
      discount: prepaid ? tx.discount : price.discount,
      paymentMethod: prepaid ? tx.paymentMethod : paymentMethod,
      paymentRef: prepaid ? tx.paymentRef : ref,
      extraHours: extra > 0 ? price.extraHours : 0,
      extraFee: extra,
      extraPaymentMethod: extra > 0 ? paymentMethod : null,
      extraPaymentRef: extra > 0 ? ref : null,
      lostTicketFee: price.lostTicketFee,
      printed: true,
    );
  }

  /// Live stream of today's transactions (dashboard counters + logs).
  Stream<List<ParkingTransaction>> todayTransactions() {
    final start = DateTime.now();
    final midnight = DateTime(start.year, start.month, start.day);
    return _tx
        .where('timestamp',
            isGreaterThanOrEqualTo: Timestamp.fromDate(midnight))
        .orderBy('timestamp', descending: true)
        .snapshots(includeMetadataChanges: true)
        .map((s) => s.docs.map(ParkingTransaction.fromDoc).toList());
  }

  /// One-time fetch of a single past day's transactions — powers the
  /// dashboard's swipeable collections card (today's page uses the live
  /// [todayTransactions] stream; every page behind it calls this instead).
  /// A plain [Future], not a stream: a day that has already ended never
  /// changes, so there's nothing to keep listening to.
  Future<List<ParkingTransaction>> transactionsForDate(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    final snap = await _tx
        .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('timestamp', isLessThan: Timestamp.fromDate(end))
        .get();
    return snap.docs.map(ParkingTransaction.fromDoc).toList();
  }

  /// One-time fetch of every transaction with a time in from [start] up to
  /// (not including) [end] — the Monthly/Yearly Report's data. A single
  /// range filter on one field, so no composite index.
  Future<List<ParkingTransaction>> transactionsBetween(
      DateTime start, DateTime end) async {
    final snap = await _tx
        .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('timestamp', isLessThan: Timestamp.fromDate(end))
        .get();
    return snap.docs.map(ParkingTransaction.fromDoc).toList();
  }

  /// Live list of vehicles still parked (no time out), oldest time in
  /// first — feeds the admin's overstay notifications. Same 24-hour cutoff
  /// as [openVisitFor]: an older open visit is a forgotten check-out, not
  /// a car still in the lot. One equality filter, so no composite index.
  Stream<List<ParkingTransaction>> parkedVehicles() => _tx
      .where('time_out', isNull: true)
      .snapshots(includeMetadataChanges: true)
      .map((s) {
        final cutoff = DateTime.now().subtract(const Duration(hours: 24));
        return s.docs
            .map(ParkingTransaction.fromDoc)
            .where((tx) => tx.awaitingCheckout && tx.timestamp.isAfter(cutoff))
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      });

  /// Full history stream, newest first.
  Stream<List<ParkingTransaction>> allTransactions({int limit = 300}) => _tx
      .orderBy('timestamp', descending: true)
      .limit(limit)
      .snapshots(includeMetadataChanges: true)
      .map((s) => s.docs.map(ParkingTransaction.fromDoc).toList());

  // --------------------------------------------------------------- AUDIT ----

  /// [previousValue]/[newValue] record a before/after numeric change (a
  /// points balance, a fee, an earn rate) alongside the free-text
  /// [description] — pass both together for any action that has a real
  /// "was X, now Y" to report; leave null for one that doesn't (a login
  /// has no balance).
  Future<void> logAudit(
    String actionType,
    String description, {
    double? previousValue,
    double? newValue,
  }) async {
    final log = AuditLog(
      logId: _uuid.v4(),
      actorId: _uid,
      actorName: currentUserName,
      actionType: actionType,
      description: description,
      timestamp: DateTime.now(),
      previousValue: previousValue,
      newValue: newValue,
    );
    // Offline-safe, append-only. Security rules forbid update/delete.
    _audit.add(log.toMap());
  }

  Stream<List<AuditLog>> auditLogs({int limit = 200}) => _audit
      .orderBy('timestamp', descending: true)
      .limit(limit)
      .snapshots(includeMetadataChanges: true)
      .map((s) => s.docs.map(AuditLog.fromDoc).toList());
}
