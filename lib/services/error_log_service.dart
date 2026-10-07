import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// One captured app error — see [ErrorLogService].
class ErrorLogEntry {
  ErrorLogEntry({
    required this.id,
    required this.message,
    required this.timestamp,
    this.stack,
    this.where,
    this.fatal = false,
    this.platform,
    this.userId,
    this.userName,
  });

  final String id;
  final String message;
  final DateTime timestamp;
  final String? stack;

  /// Which part of the app reported it — e.g. "print receipt", or
  /// "flutter" / "platform" for errors caught by the global handlers.
  final String? where;

  /// True for an uncaught error (it reached a global handler) rather than
  /// one a screen caught and reported itself.
  final bool fatal;
  final String? platform;
  final String? userId;
  final String? userName;

  factory ErrorLogEntry.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return ErrorLogEntry(
      id: doc.id,
      message: d['message'] as String? ?? '',
      timestamp: (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      stack: d['stack'] as String?,
      where: d['where'] as String?,
      fatal: d['fatal'] == true,
      platform: d['platform'] as String?,
      userId: d['user_id'] as String?,
      userName: d['user_name'] as String?,
    );
  }
}

/// App-wide error log: catches every uncaught Flutter/platform error, plus
/// anything a screen reports via [record], and writes it to the
/// `error_logs` collection so an admin can see what's failing on
/// collectors' phones (see ErrorLogsScreen) instead of it vanishing into
/// a debug console nobody watches in the field.
///
/// Writes are fire-and-forget and offline-safe (Firestore queues them
/// locally). Only signed-in sessions can write — see firestore.rules — so
/// errors before login only reach the debug console.
class ErrorLogService {
  ErrorLogService._();
  static final ErrorLogService instance = ErrorLogService._();

  CollectionReference get _col =>
      FirebaseFirestore.instance.collection('error_logs');

  /// Last message written and when — the same error firing in a tight
  /// loop (e.g. a broken build() on every frame) is recorded once, not
  /// hundreds of times.
  String? _lastMessage;
  DateTime? _lastAt;
  static const _dedupeWindow = Duration(seconds: 30);

  static const _maxStackChars = 4000;

  /// Installs the global handlers. Call once from main(), after
  /// Firebase.initializeApp.
  void init() {
    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      previousFlutterHandler?.call(details);
      record(details.exception, details.stack,
          where: details.library ?? 'flutter', fatal: true);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, where: 'platform', fatal: true);
      // false: let the platform's own default handling (logging) run too.
      return false;
    };
  }

  /// Records [error]. [where] names the feature it came from so the log
  /// is readable without the stack trace.
  void record(Object error, StackTrace? stack,
      {String? where, bool fatal = false}) {
    final message = error.toString();
    debugPrint('[ErrorLog] ${where ?? '-'}: $message');

    final now = DateTime.now();
    if (message == _lastMessage &&
        _lastAt != null &&
        now.difference(_lastAt!) < _dedupeWindow) {
      return;
    }
    _lastMessage = message;
    _lastAt = now;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    var stackText = stack?.toString();
    if (stackText != null && stackText.length > _maxStackChars) {
      stackText = stackText.substring(0, _maxStackChars);
    }
    final name = user.displayName;
    unawaited(_col.add({
      'message': message.length > 1000 ? message.substring(0, 1000) : message,
      if (stackText != null) 'stack': stackText,
      if (where != null) 'where': where,
      'fatal': fatal,
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'user_id': user.uid,
      if (name != null && name.isNotEmpty) 'user_name': name,
      'timestamp': Timestamp.fromDate(now),
    }).then((_) {}, onError: (Object e) {
      // Never let logging an error raise another one.
      debugPrint('[ErrorLog] write failed: $e');
    }));
  }

  /// Newest first — admin-only per firestore.rules.
  Stream<List<ErrorLogEntry>> recent({int limit = 200}) => _col
      .orderBy('timestamp', descending: true)
      .limit(limit)
      .snapshots()
      .map((s) => s.docs.map(ErrorLogEntry.fromDoc).toList());
}
