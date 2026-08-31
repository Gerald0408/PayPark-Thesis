import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/transaction.dart';

/// One-tap encrypted snapshot of all locally-known transactions.
/// Fail-safe for extended offline periods: even if the device dies before
/// syncing, the day's collections survive as an AES-256 encrypted JSON file.
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  /// Derive a 256-bit key from the collector's UID so backups are bound
  /// to the signed-in account (not stored in plaintext anywhere).
  enc.Key _deriveKey(String uid) {
    final digest = sha256.convert(utf8.encode('yos-backup::$uid'));
    return enc.Key(Uint8List.fromList(digest.bytes));
  }

  Future<File> exportSnapshot({
    required String uid,
    required List<ParkingTransaction> transactions,
  }) async {
    final payload = jsonEncode({
      'exported_at': DateTime.now().toIso8601String(),
      'actor_id': uid,
      'count': transactions.length,
      'transactions': transactions
          .map((t) => {
                'tracking_id': t.trackingId,
                'driver_name': t.driverName,
                'plate_number': t.plateNumber,
                'vehicle_type': t.vehicleType,
                'fee': t.fee,
                'zone_id': t.zoneId,
                'timestamp': t.timestamp.toIso8601String(),
                'printed': t.printed,
              })
          .toList(),
    });

    final iv = enc.IV.fromSecureRandom(16);
    final encrypter =
        enc.Encrypter(enc.AES(_deriveKey(uid), mode: enc.AESMode.cbc));
    final encrypted = encrypter.encrypt(payload, iv: iv);

    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = File('${dir.path}/yos_backup_$stamp.yosb');

    // File layout: base64(iv) + '\n' + base64(ciphertext)
    await file.writeAsString('${iv.base64}\n${encrypted.base64}');
    return file;
  }

  /// Decrypts a snapshot back to JSON (for recovery tooling).
  Future<Map<String, dynamic>> restoreSnapshot(File file, String uid) async {
    final parts = (await file.readAsString()).split('\n');
    final iv = enc.IV.fromBase64(parts[0]);
    final encrypter =
        enc.Encrypter(enc.AES(_deriveKey(uid), mode: enc.AESMode.cbc));
    final json = encrypter.decrypt64(parts[1], iv: iv);
    return jsonDecode(json) as Map<String, dynamic>;
  }
}
