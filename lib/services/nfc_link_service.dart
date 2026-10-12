import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';

/// Writes the driver portal's web address onto a driver's NFC card, so
/// tapping the card on any NFC phone (Android, or iPhone XS and newer)
/// opens the portal straight to its sign-in page with the card number
/// already filled in — the driver only types their PIN.
///
/// Only adds an NDEF record to the card's memory; the card's own chip ID,
/// which the collectors' USB readers read, is untouched, so the card keeps
/// working for parking and points exactly as before. Needs a rewritable
/// NFC card (NTAG213/215/216 and similar) — most MIFARE Classic cards
/// can't hold NDEF data on every phone.
class NfcLinkService {
  NfcLinkService._();
  static final NfcLinkService instance = NfcLinkService._();

  /// Hosted driver portal (lib/main_driver.dart, see firebase.json).
  static const portalUrl = 'https://concepcion-pay-parking.web.app/';

  /// The address written for [rfidTag] — DriverLoginScreen reads the
  /// `card` query parameter back out to pre-fill the card number.
  static Uri portalLinkFor(String rfidTag) => Uri.parse(portalUrl)
      .replace(queryParameters: {'card': rfidTag.trim().toUpperCase()});

  Future<bool> isAvailable() async {
    try {
      return await NfcManager.instance.checkAvailability() ==
          NfcAvailability.enabled;
    } catch (_) {
      return false;
    }
  }

  /// Waits for one card to be held to the phone and writes [rfidTag]'s
  /// portal link onto it. Completes when written; throws
  /// [NfcWriteException] with a readable message otherwise. On iPhone the
  /// system shows its own "Ready to Scan" sheet with [iosAlertMessage].
  Future<void> writePortalLink(
    String rfidTag, {
    String iosAlertMessage = 'Hold the card near the top of the phone',
  }) async {
    final message = NdefMessage(records: [_uriRecord(portalLinkFor(rfidTag))]);
    // Errors raised inside onDiscovered can't propagate out of
    // startSession, so they're relayed through this completer.
    final done = Completer<NfcWriteException?>();
    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
      alertMessageIos: iosAlertMessage,
      onDiscovered: (tag) async {
        try {
          final ndef = Ndef.from(tag);
          if (ndef == null) {
            throw const NfcWriteException(
                "This card can't store a link (not NDEF-compatible).");
          }
          if (!ndef.isWritable) {
            throw const NfcWriteException('This card is locked (read-only).');
          }
          if (message.byteLength > ndef.maxSize) {
            throw const NfcWriteException(
                'Not enough space on this card for the link.');
          }
          await ndef.write(message: message);
          await NfcManager.instance
              .stopSession(alertMessageIos: 'Portal link written');
          if (!done.isCompleted) done.complete(null);
        } catch (e) {
          await NfcManager.instance.stopSession(
              errorMessageIos: e is NfcWriteException ? e.message : '$e');
          if (!done.isCompleted) {
            done.complete(e is NfcWriteException
                ? e
                : NfcWriteException("Couldn't write the card: $e"));
          }
        }
      },
    );
    final error = await done.future;
    if (error != null) throw error;
  }

  /// Stops a [writePortalLink] that's still waiting for a card (e.g. the
  /// collector closed the dialog).
  Future<void> cancel() async {
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {}
  }

  /// NFC Forum "U" (URI) record. Prefix code 0x04 stands for "https://",
  /// so only the rest of the address is stored on the card.
  static NdefRecord _uriRecord(Uri uri) {
    var text = uri.toString();
    var prefix = 0x00;
    if (text.startsWith('https://')) {
      prefix = 0x04;
      text = text.substring(8);
    }
    return NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList([0x55]),
      identifier: Uint8List(0),
      payload: Uint8List.fromList([prefix, ...utf8.encode(text)]),
    );
  }
}


class NfcWriteException implements Exception {
  const NfcWriteException(this.message);
  final String message;

  @override
  String toString() => message;
}
