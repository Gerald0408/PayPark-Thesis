import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/collector.dart';
import '../services/error_log_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glow_effects.dart';
import '../widgets/toast.dart';

/// "flutter framework" → "Flutter Framework" for the card heading.
String? _titleCase(String? s) => s
    ?.split(' ')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

/// Admin-only list of app errors captured on any collector's phone (see
/// [ErrorLogService]) — newest first, tap one to see its full stack trace
/// and copy it for whoever is fixing the app.
class ErrorLogsScreen extends StatefulWidget {
  const ErrorLogsScreen({super.key});

  @override
  State<ErrorLogsScreen> createState() => _ErrorLogsScreenState();
}

class _ErrorLogsScreenState extends State<ErrorLogsScreen> {
  // Grabbed once — see RegistryScreen's _vehicles for why.
  late final Stream<List<ErrorLogEntry>> _logs =
      ErrorLogService.instance.recent();

  // Looked up by user_id so every log — old ones too — shows the
  // person's role next to their name, e.g. "Carlos S. Espin · Collector".
  List<Collector> _people = const [];
  String? _superAdminUid;
  StreamSubscription<List<Collector>>? _peopleSub;
  StreamSubscription<String?>? _superSub;

  @override
  void initState() {
    super.initState();
    _peopleSub = YosRepository.instance.allCollectors().listen(
      (list) {
        if (mounted) setState(() => _people = list);
      },
      onError: (Object e) => debugPrint('allCollectors error (ignored): $e'),
    );
    _superSub = YosRepository.instance.superAdminUid.listen(
      (uid) {
        if (mounted) setState(() => _superAdminUid = uid);
      },
      onError: (Object e) => debugPrint('superAdminUid error (ignored): $e'),
    );
  }

  @override
  void dispose() {
    _peopleSub?.cancel();
    _superSub?.cancel();
    super.dispose();
  }

  String? _roleOf(String? uid) {
    if (uid == null) return null;
    if (uid == _superAdminUid) return t('Super Admin', 'Super Admin');
    for (final c in _people) {
      if (c.uid == uid) {
        return c.isAdmin ? t('Admin', 'Admin') : t('Collector', 'Kolektor');
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Error Logs', 'Mga Error Log'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<List<ErrorLogEntry>>(
            stream: _logs,
            builder: (context, snap) {
              if (snap.hasError) {
                return _Message(
                    icon: Icons.lock_rounded,
                    text: t(
                        "Couldn't load error logs. Only admins can view them.",
                        'Hindi ma-load ang mga error log. Admin lang ang makakakita nito.'));
              }
              if (!snap.hasData) {
                return Center(
                    child: CircularProgressIndicator(color: YosColors.accent));
              }
              final logs = snap.data!;
              if (logs.isEmpty) {
                return _Message(
                    icon: Icons.verified_rounded,
                    text: t('No errors recorded. All good!',
                        'Walang naitalang error. Maayos ang lahat!'));
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                itemCount: logs.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ErrorCard(
                      entry: logs[i], role: _roleOf(logs[i].userId)),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.entry, this.role});
  final ErrorLogEntry entry;
  final String? role;

  @override
  Widget build(BuildContext context) {
    final color = entry.fatal ? YosColors.bad : YosColors.warn;
    final who = entry.userName ?? entry.userId ?? '-';
    return Material(
      color: YosColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showDialog<void>(
            context: context,
            builder: (_) => _ErrorDetail(entry: entry, role: role)),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: YosColors.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                      entry.fatal
                          ? Icons.error_rounded
                          : Icons.warning_amber_rounded,
                      color: color,
                      size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        _titleCase(entry.where) ?? t('Unknown', 'Hindi alam'),
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 15)),
                  ),
                  Text(DateFormat('MMM d, hh:mm a').format(entry.timestamp),
                      style: TextStyle(color: YosColors.sub, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 8),
              Text(entry.message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: YosColors.ink, fontSize: 14)),
              const SizedBox(height: 8),
              Text(
                  '${role == null ? who : '$who $role'} · '
                  '${entry.platform ?? '-'}',
                  style: TextStyle(color: YosColors.sub, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorDetail extends StatelessWidget {
  const _ErrorDetail({required this.entry, this.role});
  final ErrorLogEntry entry;
  final String? role;

  String get _fullText => [
        'When: ${DateFormat('MMM d, y hh:mm:ss a').format(entry.timestamp)}',
        'Where: ${entry.where ?? '-'}',
        'User: ${entry.userName ?? '-'}${role == null ? '' : ' $role'} (${entry.userId ?? '-'})',
        'Platform: ${entry.platform ?? '-'}',
        'Fatal: ${entry.fatal}',
        '',
        entry.message,
        if (entry.stack != null) ...['', entry.stack!],
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YosColors.surface,
      title: Text(t('Error details', 'Detalye ng error'),
          style: TextStyle(color: YosColors.ink, fontWeight: FontWeight.w800)),
      content: SingleChildScrollView(
        child: SelectableText(_fullText,
            style: TextStyle(
                color: YosColors.ink, fontFamily: 'monospace', fontSize: 12)),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _fullText));
            Toast.success(context, t('Copied', 'Nakopya'));
          },
          icon: const Icon(Icons.copy_rounded),
          label: Text(t('Copy', 'Kopyahin')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Close', 'Isara')),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: YosColors.sub),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: YosColors.sub,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
