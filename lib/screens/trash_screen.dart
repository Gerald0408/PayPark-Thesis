import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/trashed_collector.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/app_dialog.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/toast.dart';

/// Admin-only trash bin for collectors removed via CollectorsScreen's
/// "Remove collector" action (see YosRepository.deactivateCollector) — a
/// removal now lands here first instead of vanishing outright, so a
/// mistaken or premature removal can be undone with [_restore] rather than
/// forcing the collector to re-register from scratch. [_deleteForever] is
/// the only way a trashed account actually goes away for good.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  // Grabbed once, not called fresh inside build() — same reasoning as
  // CollectorsScreen's own `late final` stream field.
  late final Stream<List<TrashedCollector>> _trashed =
      YosRepository.instance.trashedCollectors();

  Future<void> _restore(BuildContext context, TrashedCollector c) async {
    final ok = await showAppConfirmDialog(
      context,
      title: t('Restore ${c.name}?', 'I-restore si ${c.name}?'),
      message: t(
          '${c.name} (@${c.username}) will get their account '
              'back exactly as it was, including admin access if they had '
              'it, and can sign back in right away.',
          'Maibabalik ang account ni ${c.name} (@${c.username}) nang '
              'buo, kasama ang admin access kung meron, at makaka-sign '
              'in na agad ulit.'),
      confirmLabel: t('Restore', 'I-restore'),
      confirmIcon: Icons.restore_rounded,
    );
    if (ok != true) return;
    try {
      await YosRepository.instance.restoreCollector(c.uid, c.name);
      if (context.mounted) {
        Toast.success(context, t('${c.name} restored', 'Na-restore si ${c.name}'));
      }
    } catch (_) {
      if (context.mounted) {
        Toast.error(context,
            t("Couldn't restore ${c.name}", 'Hindi na-restore si ${c.name}'));
      }
    }
  }

  Future<void> _deleteForever(BuildContext context, TrashedCollector c) async {
    final ok = await showAppConfirmDialog(
      context,
      title: t('Delete ${c.name} forever?', 'Burahin si ${c.name} nang tuluyan?'),
      message: t(
          '${c.name} (@${c.username}) will be permanently '
              'removed from the trash bin. This can\'t be undone — their '
              'past transactions and audit history are kept either way.',
          'Permanenteng tatanggalin si ${c.name} (@${c.username}) sa '
              'trash bin. Hindi na ito maibabalik pa — pero mananatili '
              'pa rin ang kanilang mga nakaraang transaksyon at audit '
              'history.'),
      confirmLabel: t('Delete Forever', 'Burahin nang Tuluyan'),
      confirmIcon: Icons.delete_forever_rounded,
      confirmColor: YosColors.bad,
    );
    if (ok != true) return;
    try {
      await YosRepository.instance.permanentlyDeleteCollector(c.uid, c.name);
      if (context.mounted) {
        Toast.success(context, t('${c.name} deleted', 'Naburang si ${c.name}'));
      }
    } catch (_) {
      if (context.mounted) {
        Toast.error(context,
            t("Couldn't delete ${c.name}", 'Hindi naburang si ${c.name}'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Trash', 'Basura'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<List<TrashedCollector>>(
            stream: _trashed,
            builder: (context, snap) {
              // Surfaced rather than left to spin forever: a permission-
              // denied here (e.g. Firestore rules for trashed_collectors
              // not yet deployed, or this account losing admin/Face ID
              // status mid-session) otherwise looks identical to "still
              // loading" with no way to tell what's actually wrong.
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 40, color: YosColors.bad),
                        const SizedBox(height: 12),
                        Text(
                            t("Couldn't load the trash bin",
                                'Hindi na-load ang trash bin'),
                            style: TextStyle(
                                color: YosColors.ink,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text('${snap.error}',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: YosColors.sub, fontSize: 12)),
                      ],
                    ),
                  ),
                );
              }
              if (!snap.hasData) {
                return Center(
                    child: CircularProgressIndicator(color: YosColors.ink));
              }
              final list = snap.data!;
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline_rounded,
                            size: 40, color: YosColors.sub),
                        const SizedBox(height: 12),
                        Text(t('Trash is empty', 'Walang laman ang basura'),
                            style: TextStyle(
                                color: YosColors.sub,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Text(
                          t(
                              'Removed collectors show up here and can be '
                                  'restored.',
                              'Dito lumalabas ang mga tinanggal na kolektor '
                                  'at maaari pang i-restore.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: YosColors.sub.withOpacity(0.8),
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final c = list[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PopIn(
                      delayMs: (i * 40).clamp(0, 400),
                      child: GlassCard(
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                  color: YosColors.badSoft,
                                  borderRadius: BorderRadius.circular(14)),
                              child: Icon(Icons.person_off_rounded,
                                  color: YosColors.bad),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(c.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: YosColors.ink,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15)),
                                  Text(
                                      '@${c.username}'
                                      '${c.isAdmin ? " · ${t('Admin', 'Tagapangasiwa')}" : ""} '
                                      '· ${t('removed', 'tinanggal noong')} '
                                      '${DateFormat('MMM d, y').format(c.deactivatedAt)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: YosColors.sub,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            PopupMenuButton<_RowAction>(
                              icon: Icon(Icons.more_vert_rounded,
                                  color: YosColors.ink),
                              onSelected: (action) {
                                switch (action) {
                                  case _RowAction.restore:
                                    _restore(context, c);
                                    break;
                                  case _RowAction.deleteForever:
                                    _deleteForever(context, c);
                                    break;
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: _RowAction.restore,
                                  child: ListTile(
                                    leading: Icon(Icons.restore_rounded,
                                        color: YosColors.accentDeep),
                                    title: Text(t('Restore', 'I-restore')),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _RowAction.deleteForever,
                                  child: ListTile(
                                    leading: Icon(Icons.delete_forever_rounded,
                                        color: YosColors.bad),
                                    title: Text(
                                        t('Delete Forever', 'Burahin nang Tuluyan')),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _RowAction { restore, deleteForever }
