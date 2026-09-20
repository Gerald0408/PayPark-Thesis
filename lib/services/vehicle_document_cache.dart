import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Local, on-device store for captured vehicle document bytes (the raw
/// driver's license / OR/CR photos and the combined PDF) — a Hive box
/// instead of plain files under the app's documents directory.
///
/// On its own this is purely a local-storage swap: Hive keeps everything
/// on *this* device only, exactly like the plain files it replaces —
/// automatic cross-device visibility still depends entirely on
/// VehicleDocumentStorage's Firebase Storage upload succeeding, which
/// isn't available on this project's Firebase plan. [exportAll] /
/// [importZip] are the manual fallback: a zip a collector carries between
/// devices themselves (share sheet, USB, whatever) instead. A key here is
/// the same bare filename VehicleRegistry/DocumentScanScreen already
/// generate (a uuid, or `{plateKey}_documents.pdf`) — never a full
/// filesystem path — which is also exactly what RegisteredVehicle's own
/// photo fields hold (synced for free via Firestore), so importing a
/// vehicle's photo bytes under that same key is all a receiving device
/// needs to make it show up, no other data to reconcile.
///
/// [write] also best-effort mirrors every capture into public device
/// storage under a dedicated PayPark folder (see [_backupCapture]) — a
/// safety net against this app's own data being lost (uninstalled,
/// storage cleared, Hive corrupted) that survives independently of the
/// app, unlike the Hive box itself. It still never leaves the device, so
/// it's not a substitute for [exportAll]/cloud sync, only a local second
/// copy.
class VehicleDocumentCache {
  VehicleDocumentCache._();
  static final VehicleDocumentCache instance = VehicleDocumentCache._();

  static const _boxName = 'vehicle_documents';
  Box<Uint8List>? _box;

  /// Call once from main() before runApp — DocPhotoView and friends read
  /// synchronously via [read], which only works once this has completed.
  Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<Uint8List>(_boxName);
  }

  Box<Uint8List> get _opened {
    final box = _box;
    if (box == null) {
      throw StateError('VehicleDocumentCache.init() not called yet');
    }
    return box;
  }

  Future<void> write(String key, Uint8List bytes) async {
    await _opened.put(key, bytes);
    // Fire-and-forget: a failed/slow backup copy must never hold up or
    // fail the actual capture flow the caller is in the middle of.
    unawaited(_backupCapture(key, bytes));
  }

  /// Best-effort copy of [bytes] into public device storage via Android's
  /// MediaStore (required on this app's target SDK — no direct legacy
  /// file path access). Silent on failure: this is a safety net, not
  /// something a capture should ever be blocked or shown an error by.
  ///
  /// A raw photo (.jpg) goes to Pictures/PayPark — [DirType.download]
  /// (Downloads) isn't indexed by the phone's Gallery/Photos app, so a
  /// photo saved there is invisible to the one place a collector would
  /// actually think to look for a backup photo; [DirType.photo] is. The
  /// combined PDF isn't a picture Gallery could show either way, so it
  /// keeps going to Download/PayPark, the conventional place for a
  /// document file.
  Future<void> _backupCapture(String key, Uint8List bytes) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$key');
      await tempFile.writeAsBytes(bytes);
      final isPdf = key.toLowerCase().endsWith('.pdf');
      // MediaStore.saveFile copies from this temp path and deletes it
      // itself once done — no cleanup needed here even on success.
      await MediaStore().saveFile(
        tempFilePath: tempFile.path,
        dirType: isPdf ? DirType.download : DirType.photo,
        dirName: isPdf ? DirName.download : DirName.pictures,
      );
    } catch (e) {
      debugPrint('VehicleDocumentCache backup failed for $key: $e');
    }
  }

  /// Synchronous — Hive keeps an opened box's entries in memory, so this
  /// never needs to be a Future. Returns null before [init] has run, or
  /// if this device has never captured/cached [key] (e.g. a legacy
  /// filesystem-path key from before this cache existed — see
  /// VehicleDocumentStorage.fetchBytes's own file fallback for that case).
  Uint8List? read(String key) => _box?.get(key);

  Future<void> delete(String key) => _opened.delete(key);

  /// Every cached document's key — what the Profile "Files" screen lists
  /// (see CapturedFilesScreen). Empty before [init] has run.
  List<String> keys() => _box?.keys.map((k) => k.toString()).toList() ?? [];

  /// Packs every cached document's bytes into a zip, one entry per Hive
  /// key. Hand the result to a share sheet, save it, copy it over USB —
  /// however it physically gets to another device. Empty (a zero-entry
  /// zip) if nothing's cached yet.
  Uint8List exportAll() {
    final archive = Archive();
    for (final key in _opened.keys) {
      final bytes = _opened.get(key);
      if (bytes == null) continue;
      archive.addFile(ArchiveFile(key.toString(), bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
  }

  /// Restores every entry from a zip built by [exportAll] into this
  /// device's own cache, under the exact key it was exported with —
  /// already exactly what that vehicle's Firestore record names in its
  /// photo path fields, from whichever device originally captured it, so
  /// nothing else needs updating for it to show up. Returns how many
  /// entries were written; throws if [zipBytes] isn't a valid zip.
  Future<int> importZip(Uint8List zipBytes) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    var count = 0;
    for (final file in archive) {
      if (!file.isFile) continue;
      final content = file.content;
      final bytes = content is Uint8List
          ? content
          : Uint8List.fromList(content as List<int>);
      await write(file.name, bytes);
      count++;
    }
    return count;
  }
}
