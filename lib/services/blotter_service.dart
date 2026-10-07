import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

import '../core/names.dart';
import '../models/transaction.dart';
import 'firestore_service.dart';

/// One handwritten-logbook-style blotter line: an incident, complaint,
/// violation or general note a collector records during their shift.
/// Append-only (see firestore.rules) — like a paper blotter, a mistake is
/// corrected by writing a new entry, never by erasing the old one.
class BlotterEntry {
  BlotterEntry({
    required this.id,
    required this.dateKey,
    required this.category,
    required this.description,
    required this.timestamp,
    this.plateNumber,
    this.zoneId,
    this.collectorId,
    this.collectorName,
    this.pendingSync = false,
  });

  final String id;

  /// yyyy-MM-dd of [timestamp] (device-local) — what the daily view
  /// queries on.
  final String dateKey;
  final String category;
  final String description;
  final DateTime timestamp;
  final String? plateNumber;
  final String? zoneId;
  final String? collectorId;
  final String? collectorName;
  final bool pendingSync;

  factory BlotterEntry.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return BlotterEntry(
      id: doc.id,
      dateKey: d['date_key'] as String? ?? '',
      category: BlotterCategory.normalize(d['category'] as String?),
      description: d['description'] as String? ?? '',
      timestamp: (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      plateNumber: d['plate_number'] as String?,
      zoneId: d['zone_id'] as String?,
      collectorId: d['collector_id'] as String?,
      collectorName: d['collector_name'] is String &&
              (d['collector_name'] as String).trim().isNotEmpty
          ? formatPersonName(d['collector_name'] as String)
          : null,
      pendingSync: doc.metadata.hasPendingWrites,
    );
  }
}

class BlotterCategory {
  static const incident = 'incident';
  static const complaint = 'complaint';
  static const violation = 'violation';
  static const note = 'note';

  static const all = [incident, complaint, violation, note];

  static String normalize(String? v) => all.contains(v) ? v! : note;
}

/// The day's collection totals that head the blotter — derived from that
/// day's transactions, never stored separately, so it can't drift from
/// Transaction Logs.
class DailyCollectionSummary {
  DailyCollectionSummary(this.transactions);

  final List<ParkingTransaction> transactions;

  int get count => transactions.length;
  /// Check-in fees plus overtime collected at check-out.
  double get total => transactions.fold(0, (s, tx) => s + tx.totalPaid);
  double get overtime => transactions.fold(0, (s, tx) => s + tx.extraFee);
  double get discounts => transactions.fold(0, (s, tx) => s + tx.discount);

  /// Vehicles checked in that day that haven't checked out.
  int get stillParked => transactions.where((tx) => tx.awaitingCheckout).length;

  Map<String, double> get byMethod => amountsByMethod(transactions);

  /// Collector name -> (count, total). Entries from before transactions
  /// recorded a collector are grouped under "Unrecorded".
  Map<String, (int, double)> get byCollector {
    final out = <String, (int, double)>{};
    for (final tx in transactions) {
      final key = tx.collectorName ?? 'Unrecorded';
      final (c, s) = out[key] ?? (0, 0.0);
      out[key] = (c + 1, s + tx.totalPaid);
    }
    return out;
  }
}

class BlotterService {
  BlotterService._();
  static final BlotterService instance = BlotterService._();

  CollectionReference get _col =>
      FirebaseFirestore.instance.collection('blotter_entries');

  static String dateKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  /// Live entries for [day], oldest first like a paper logbook. Sorted
  /// client-side so this needs no composite Firestore index.
  Stream<List<BlotterEntry>> entriesFor(DateTime day) => _col
      .where('date_key', isEqualTo: dateKey(day))
      .snapshots(includeMetadataChanges: true)
      .map((s) => s.docs.map(BlotterEntry.fromDoc).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp)));

  /// Offline-safe append — not awaited by callers that don't need to.
  Future<void> add({
    required String category,
    required String description,
    String? plateNumber,
    String? zoneId,
  }) async {
    final now = DateTime.now();
    final repo = YosRepository.instance;
    final plate = plateNumber?.trim().toUpperCase();
    await _col.add({
      'date_key': dateKey(now),
      'category': BlotterCategory.normalize(category),
      'description': description.trim(),
      if (plate != null && plate.isNotEmpty) 'plate_number': plate,
      if (zoneId != null) 'zone_id': zoneId,
      'collector_id': FirebaseAuth.instance.currentUser?.uid,
      'collector_name': repo.currentUserName,
      'timestamp': Timestamp.fromDate(now),
    });
    repo.logAudit(AuditAction.blotterEntry,
        'Blotter ${BlotterCategory.normalize(category)}: ${description.trim()}');
  }
}
