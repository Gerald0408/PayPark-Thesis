import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../models/registered_vehicle.dart';
import '../models/transaction.dart';

/// Driver portal accounts: a driver signs in with their RFID card number
/// and a 6-digit PIN, then sees only their own vehicles, points and
/// parking history.
///
/// Firebase Auth has no "card + PIN" provider, so — same trick as
/// collectors' usernames (see core/username.dart) — each driver gets a
/// never-shown synthetic email derived from their card, with the PIN as
/// its password (Firebase's 6-character password minimum is why PINs are
/// 6 digits).
///
/// A client app can't change or delete *another* user's password, so a
/// forgotten PIN is handled by issuing a fresh account under the next
/// version of the email and retiring the old one: [driver_logins/{key}]
/// says which version is current, and access itself hangs off
/// [drivers/{uid}] — deleting the old uid's doc there is what cuts the old
/// PIN off, since firestore.rules only trusts a driver uid that still has
/// one.
///
/// Self-contained on purpose (no YosRepository): the driver portal web
/// build imports this, and must not drag in the collector app's phone-only
/// plugins.
class DriverAccountService {
  DriverAccountService._();
  static final DriverAccountService instance = DriverAccountService._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference get _drivers => _db.collection('drivers');
  CollectionReference get _logins => _db.collection('driver_logins');

  static const pinLength = 6;

  static bool isValidPin(String pin) =>
      RegExp('^[0-9]{$pinLength}\$').hasMatch(pin);

  /// Deterministic, never-shown Firebase Auth email for card [tagKey]
  /// (already RegisteredVehicle.normalize'd) at PIN [version].
  static String emailFor(String tagKey, int version) =>
      'd-${tagKey.toLowerCase()}-v$version@driver.paypark.local';

  // ---------------------------------------------------------------------
  // Collector side — enrolling a driver / resetting a forgotten PIN.
  // ---------------------------------------------------------------------

  /// Whether card [rfidTag] already has portal access set up.
  Future<bool> hasAccess(String rfidTag) async {
    final key = RegisteredVehicle.normalize(rfidTag);
    final snap = await _drivers.where('rfid_tag_key', isEqualTo: key).limit(1).get();
    return snap.docs.isNotEmpty;
  }

  /// Gives card [rfidTag] portal access with [pin], replacing any earlier
  /// PIN for the same card. Runs the account creation on a throwaway
  /// secondary FirebaseApp so the collector doing this stays signed in —
  /// see YosRepository.resetCollectorPassword for the same pattern.
  Future<void> setPin({
    required String rfidTag,
    required String driverName,
    required String pin,
  }) async {
    if (!isValidPin(pin)) {
      throw const FormatException('PIN must be exactly 6 digits.');
    }
    final collector = FirebaseAuth.instance.currentUser;
    if (collector == null) throw StateError('Not signed in');
    final key = RegisteredVehicle.normalize(rfidTag);
    if (key.isEmpty) throw const FormatException('No RFID tag.');

    final loginRef = _logins.doc(key);
    final login = await loginRef.get();
    final version =
        (((login.data() as Map<String, dynamic>?)?['version'] as num?) ?? 0)
                .toInt() +
            1;

    final secondaryApp = await Firebase.initializeApp(
      name: 'driver_pin_${DateTime.now().microsecondsSinceEpoch}',
      options: Firebase.app().options,
    );
    final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
    String newUid;
    try {
      final cred = await secondaryAuth.createUserWithEmailAndPassword(
          email: emailFor(key, version), password: pin);
      newUid = cred.user!.uid;
      await cred.user!.updateDisplayName(driverName);
    } finally {
      try {
        await secondaryAuth.signOut();
      } catch (_) {}
    }

    // Retire every earlier account for this card, then grant the new one.
    final old = await _drivers.where('rfid_tag_key', isEqualTo: key).get();
    final batch = _db.batch();
    for (final d in old.docs) {
      batch.delete(d.reference);
    }
    batch.set(_drivers.doc(newUid), {
      'rfid_tag_key': key,
      'driver_name': driverName,
      'created_by': collector.uid,
      'created_at': Timestamp.now(),
    });
    batch.set(loginRef, {
      'version': version,
      'updated_at': Timestamp.now(),
    });
    await batch.commit();
  }

  // ---------------------------------------------------------------------
  // Driver side — the portal.
  // ---------------------------------------------------------------------

  /// Signs a driver in. Throws [DriverLoginException] with a message
  /// suitable for showing as-is.
  Future<void> signIn(String rfidTag, String pin) async {
    final key = RegisteredVehicle.normalize(rfidTag);
    if (key.isEmpty || !isValidPin(pin)) {
      throw const DriverLoginException(
          'Enter your card number and your 6-digit PIN.');
    }
    DocumentSnapshot login;
    try {
      login = await _logins.doc(key).get();
    } on FirebaseException {
      throw const DriverLoginException(
          "Can't reach the server. Check your internet connection.");
    }
    final version =
        ((login.data() as Map<String, dynamic>?)?['version'] as num?)?.toInt();
    if (version == null) {
      throw const DriverLoginException(
          'This card has no portal access yet. Ask a collector to set up '
          'your PIN.');
    }
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: emailFor(key, version), password: pin);
    } on FirebaseAuthException catch (e) {
      throw DriverLoginException(switch (e.code) {
        'too-many-requests' =>
          'Too many tries. Wait a few minutes, then try again.',
        'network-request-failed' =>
          "Can't reach the server. Check your internet connection.",
        _ => 'Wrong card number or PIN.',
      });
    }
  }

  Future<void> signOut() => FirebaseAuth.instance.signOut();

  /// The signed-in driver's profile, or null if this account's access was
  /// revoked (a newer PIN was issued for the card).
  Future<DriverProfile?> currentProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final doc = await _drivers.doc(uid).get();
    if (!doc.exists) return null;
    final d = doc.data() as Map<String, dynamic>;
    return DriverProfile(
      uid: uid,
      rfidTagKey: d['rfid_tag_key'] as String,
      name: d['driver_name'] as String? ?? 'Driver',
    );
  }

  /// Every vehicle registered under the driver's card — points live on
  /// each one.
  Stream<List<RegisteredVehicle>> vehicles(String tagKey) => _db
      .collection('registered_vehicles')
      .where('rfid_tag_key', isEqualTo: tagKey)
      .snapshots()
      .map((s) => s.docs.map(RegisteredVehicle.fromDoc).toList());

  /// The driver's parking history, newest first. Only transactions logged
  /// since the portal existed carry the card key, so older visits don't
  /// appear here. Sorted client-side to avoid needing a composite index.
  Stream<List<ParkingTransaction>> history(String tagKey, {int limit = 100}) =>
      _db
          .collection('transactions')
          .where('rfid_tag_key', isEqualTo: tagKey)
          .limit(limit)
          .snapshots()
          .map((s) => s.docs.map(ParkingTransaction.fromDoc).toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp)));

  /// Lets a signed-in driver pick their own new PIN.
  Future<void> changeOwnPin(String currentPin, String newPin) async {
    if (!isValidPin(newPin)) {
      throw const DriverLoginException('The new PIN must be 6 digits.');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) {
      throw const DriverLoginException('Please sign in again.');
    }
    try {
      await user.reauthenticateWithCredential(EmailAuthProvider.credential(
          email: user.email!, password: currentPin));
      await user.updatePassword(newPin);
    } on FirebaseAuthException catch (e) {
      throw DriverLoginException(e.code == 'wrong-password' ||
              e.code == 'invalid-credential'
          ? 'Your current PIN is wrong.'
          : "Couldn't change your PIN. Try again.");
    }
  }
}

class DriverProfile {
  const DriverProfile(
      {required this.uid, required this.rfidTagKey, required this.name});
  final String uid;
  final String rfidTagKey;
  final String name;
}

class DriverLoginException implements Exception {
  const DriverLoginException(this.message);
  final String message;
  @override
  String toString() => message;
}
