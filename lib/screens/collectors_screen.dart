import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/collector.dart';
import '../services/face_auth_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/app_dialog.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/reset_password_dialog.dart';
import '../widgets/toast.dart';
import 'trash_screen.dart';

/// Admin-only roster of registered collectors — this app's user-management
/// screen. Three account-changing actions live here, all admin-only per
/// firestore.rules:
///  - Make Admin / Remove Admin, the in-app way to assign or transfer Admin
///    access (see YosRepository.setAdminRole) — no Firebase Console needed.
///  - Reset password: sets a new username + passcode for a collector who's
///    locked out (see showResetCollectorPasswordDialog /
///    YosRepository.resetCollectorPassword) — the same lever
///    AccessRequestsScreen's "Grant password reset" uses, just reachable
///    directly here for someone who never filed a request.
///  - Remove collector: drops their collectors/{uid} doc (see
///    YosRepository.deactivateCollector) — no Cloud Functions backend to
///    delete the underlying Firebase Auth account itself, so this is what
///    "remove" actually means here, with no replacement account created.
///    Their past transactions and audit history are untouched (separate
///    collections) either way.
class CollectorsScreen extends StatefulWidget {
  const CollectorsScreen({super.key});

  @override
  State<CollectorsScreen> createState() => _CollectorsScreenState();
}

class _CollectorsScreenState extends State<CollectorsScreen> {
  final _search = TextEditingController();
  String _query = '';

  // Grabbed once, not called fresh inside build() — the search box's own
  // setState on every keystroke would otherwise hand StreamBuilder a
  // brand-new Stream instance each time, which is what causes Flutter's
  // "'_dependents.isEmpty': is not true" crash. Same `late final` pattern
  // FeesScreen/ProfileScreen/RfidPointsScreen already use.
  late final Stream<List<Collector>> _collectors =
      YosRepository.instance.allCollectors();

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      setState(() => _query = _search.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Collector> _filter(List<Collector> all) {
    final matching = _query.isEmpty
        ? all
        : all
            .where((c) =>
                c.name.toLowerCase().contains(_query) ||
                c.username.toLowerCase().contains(_query))
            .toList();
    // Admins pinned to the top, always — the people who can actually act
    // on this screen (promote/demote/reset) shouldn't get buried under a
    // long collector roster. Partition rather than sort so each group
    // keeps allCollectors()' own created_at-descending order stably,
    // instead of relying on List.sort's ordering guarantees.
    final admins = matching.where((c) => c.isAdmin).toList();
    final others = matching.where((c) => !c.isAdmin).toList();
    return [...admins, ...others];
  }

  Future<void> _confirmRemoveCollector(
      BuildContext context, Collector c) async {
    final ok = await showAppConfirmDialog(
      context,
      title: t('Remove ${c.name}?', 'Alisin si ${c.name}?'),
      message: t(
          '${c.name} (@${c.username}) will be removed from the '
              'roster and moved to Trash, where they can be restored later if '
              'needed. Their past transactions and audit history are kept.',
          '${c.name} (@${c.username}) ay aalisin sa listahan at ililipat sa '
              'Basura, kung saan maaari pa itong ibalik kung kakailanganin. '
              'Ang kanilang mga nakaraang transaksyon at audit history ay '
              'mananatili.'),
      confirmLabel: t('Remove', 'Alisin'),
      confirmIcon: Icons.person_remove_rounded,
      confirmColor: YosColors.bad,
    );
    if (ok != true) return;
    await YosRepository.instance.deactivateCollector(c.uid, c.name);
    // Best-effort, same-device cleanup: only reaches a locally-enrolled
    // profile for c.uid if it happens to live on *this* device (e.g. a
    // shared kiosk phone) — FaceLoginScreen's own live existence check is
    // what actually closes this everywhere else.
    await FaceAuthService.instance.removeProfile(c.uid);
    if (context.mounted) {
      Toast.success(context, t('${c.name} removed', 'Naalis si ${c.name}'));
    }
  }

  /// Admin sets a new username + passcode for a collector who's locked
  /// out — see showResetCollectorPasswordDialog / YosRepository.
  /// resetCollectorPassword. Same underlying reset AccessRequestsScreen's
  /// "Grant password reset" uses, just reachable directly here for a
  /// collector who never filed a request.
  Future<void> _resetPassword(BuildContext context, Collector c) async {
    await showResetCollectorPasswordDialog(context, c);
  }

  /// Full-detail view for one collector — reached by tapping their row.
  /// Purely informational: surfaces everything the roster row itself
  /// doesn't have room for (phone, birthday). Account-changing actions
  /// (Make/Remove Admin, Reset password, Remove collector) stay on that
  /// same row's overflow menu only, rather than duplicated here.
  Future<void> _showCollectorDetails(BuildContext context, Collector c) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: YosColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            // A fixed row of detail fields (phone/birthday are only
            // sometimes present) plus a name that can wrap to two lines
            // on a narrow screen is normally short enough to just fit,
            // but a short device or a larger system text-scale setting
            // can push it past the sheet's available height — this is
            // what was overflowing at the bottom instead of scrolling.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 18),
                      decoration: BoxDecoration(
                          color: YosColors.sub.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                            color: c.isAdmin
                                ? YosColors.accentDeep
                                : YosColors.mint,
                            borderRadius: BorderRadius.circular(16)),
                        child: Icon(
                            c.isAdmin
                                ? Icons.shield_rounded
                                : Icons.person_rounded,
                            // YosColors.onAccent, not a fixed color, on the
                            // admin badge, so this stays correct even if a
                            // future palette's accentDeep isn't bright in
                            // both modes — see onAccent's own comment.
                            color:
                                c.isAdmin ? YosColors.onAccent : YosColors.ink,
                            size: 26),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name,
                                style: TextStyle(
                                    color: YosColors.ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18)),
                            Text(
                                c.isAdmin
                                    ? t('Admin', 'Tagapangasiwa')
                                    : t('Collector', 'Kolektor'),
                                style: TextStyle(
                                    color: YosColors.sub,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _detailRow(Icons.badge_outlined, t('Username', 'Username'),
                      '@${c.username}'),
                  if (c.phone != null && c.phone!.isNotEmpty)
                    _detailRow(Icons.phone_outlined, t('Phone', 'Telepono'),
                        c.phone!),
                  if (c.birthday != null)
                    _detailRow(Icons.cake_outlined, t('Birthday', 'Kaarawan'),
                        DateFormat('MMM d, y').format(c.birthday!)),
                  _detailRow(Icons.event_available_outlined,
                      t('Registered', 'Petsa ng Pagrehistro'),
                      DateFormat('MMM d, y').format(c.createdAt)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: YosColors.sub),
            const SizedBox(width: 10),
            Text('$label: ',
                style: TextStyle(
                    color: YosColors.sub,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          ],
        ),
      );

  /// Shared confirm-then-write for both directions of the Admin toggle —
  /// only the copy and colors differ between promoting and demoting, so
  /// one method covers both rather than two near-duplicates.
  Future<void> _confirmSetAdmin(
      BuildContext context, Collector c, bool makeAdmin) async {
    final ok = await showAppConfirmDialog(
      context,
      title: makeAdmin
          ? t('Make ${c.name} an Admin?', 'Gawing Admin si ${c.name}?')
          : t('Remove Admin from ${c.name}?',
              'Alisin ang Admin kay ${c.name}?'),
      message: makeAdmin
          ? t(
              '${c.name} will get full Admin access — the same as you: '
                  'fees, settings, collectors, and everything else here.',
              '${c.name} ay magkakaroon ng buong Admin access — kagaya mo: '
                  'mga bayarin, settings, kolektor, at lahat ng iba pa dito.')
          : t(
              '${c.name} goes back to a regular Collector. They can still '
                  'log entries and print receipts, just not manage the app.',
              '${c.name} ay babalik na regular na Kolektor. Maaari pa rin '
                  'nilang i-log ang mga entry at mag-print ng resibo, hindi '
                  'lang mamahala ng app.'),
      confirmLabel:
          makeAdmin ? t('Make Admin', 'Gawing Admin') : t('Remove Admin', 'Alisin ang Admin'),
      confirmIcon: makeAdmin
          ? Icons.admin_panel_settings_rounded
          : Icons.remove_moderator_rounded,
      confirmColor: makeAdmin ? YosColors.accentDeep : YosColors.warn,
    );
    if (ok != true) return;
    await YosRepository.instance
        .setAdminRole(uid: c.uid, name: c.name, makeAdmin: makeAdmin);
    if (context.mounted) {
      Toast.success(
          context,
          makeAdmin
              ? t('${c.name} is now an Admin', '${c.name} ay Admin na ngayon')
              : t('${c.name} is now a Collector',
                  '${c.name} ay Kolektor na ngayon'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selfUid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Collectors', 'Mga Kolektor'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: t('Trash', 'Basura'),
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const TrashScreen())),
          ),
        ],
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: t('Search by name or username',
                        'Maghanap sa pangalan o username'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: _search.clear,
                          ),
                    filled: true,
                    fillColor: YosColors.surface,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: StreamBuilder<List<Collector>>(
                  stream: _collectors,
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return Center(
                          child:
                              CircularProgressIndicator(color: YosColors.ink));
                    }
                    final list = _filter(snap.data!);
                    if (list.isEmpty) {
                      return Center(
                        child: Text(
                            _query.isEmpty
                                ? t('No collectors registered yet.',
                                    'Wala pang nakarehistrong kolektor.')
                                : t('No one matches "$_query".',
                                    'Walang tumutugma sa "$_query".'),
                            style: TextStyle(
                                color: YosColors.sub,
                                fontWeight: FontWeight.w600)),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final c = list[i];
                        final isSelf = c.uid == selfUid;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: PopIn(
                            delayMs: (i * 40).clamp(0, 400),
                            child: GlassCard(
                              onTap: () => _showCollectorDetails(context, c),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                        color: c.isAdmin
                                            ? YosColors.accentDeep
                                            : YosColors.mint,
                                        borderRadius:
                                            BorderRadius.circular(14)),
                                    child: Icon(
                                        c.isAdmin
                                            ? Icons.shield_rounded
                                            : Icons.person_rounded,
                                        color: c.isAdmin
                                            ? YosColors.onAccent
                                            : YosColors.ink),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(c.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      color: YosColors.ink,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      fontSize: 15)),
                                            ),
                                            if (isSelf) ...[
                                              const SizedBox(width: 6),
                                              Text(t('(you)', '(ikaw)'),
                                                  style: TextStyle(
                                                      color: YosColors.sub,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w600)),
                                            ],
                                          ],
                                        ),
                                        Text(
                                            t(
                                                '@${c.username} · ${c.isAdmin ? "Admin" : "Collector"} · registered ${DateFormat('MMM d, y').format(c.createdAt)}',
                                                '@${c.username} · ${c.isAdmin ? "Tagapangasiwa" : "Kolektor"} · nagparehistro noong ${DateFormat('MMM d, y').format(c.createdAt)}'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: YosColors.sub,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                  // Self-changes to is_admin aren't allowed
                                  // server-side either way (see
                                  // firestore.rules) — hiding the menu for
                                  // your own row keeps that consistent
                                  // instead of showing actions that would
                                  // just fail.
                                  if (!isSelf)
                                    PopupMenuButton<_RowAction>(
                                      icon: Icon(Icons.more_vert_rounded,
                                          color: YosColors.ink),
                                      onSelected: (action) {
                                        switch (action) {
                                          case _RowAction.makeAdmin:
                                            _confirmSetAdmin(context, c, true);
                                            break;
                                          case _RowAction.removeAdmin:
                                            _confirmSetAdmin(context, c, false);
                                            break;
                                          case _RowAction.removeCollector:
                                            _confirmRemoveCollector(context, c);
                                            break;
                                          case _RowAction.resetPassword:
                                            _resetPassword(context, c);
                                            break;
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        if (c.isAdmin)
                                          PopupMenuItem(
                                            value: _RowAction.removeAdmin,
                                            child: ListTile(
                                              leading: const Icon(
                                                  Icons
                                                      .remove_moderator_rounded,
                                                  color: YosColors.warn),
                                              title: Text(t('Remove Admin',
                                                  'Alisin ang Admin')),
                                              contentPadding: EdgeInsets.zero,
                                            ),
                                          )
                                        else
                                          PopupMenuItem(
                                            value: _RowAction.makeAdmin,
                                            child: ListTile(
                                              leading: Icon(
                                                  Icons.shield_rounded,
                                                  color: YosColors.accentDeep),
                                              title: Text(t('Make Admin',
                                                  'Gawing Admin')),
                                              contentPadding: EdgeInsets.zero,
                                            ),
                                          ),
                                        PopupMenuItem(
                                          value: _RowAction.resetPassword,
                                          child: ListTile(
                                            leading: Icon(
                                                Icons.lock_reset_rounded,
                                                color: YosColors.accentDeep),
                                            title: Text(t('Reset password',
                                                'I-reset ang Password')),
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: _RowAction.removeCollector,
                                          child: ListTile(
                                            leading: const Icon(
                                                Icons.person_remove_rounded,
                                                color: YosColors.bad),
                                            title: Text(t('Remove collector',
                                                'Alisin ang Kolektor')),
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
            ],
          ),
        ),
      ),
    );
  }
}

enum _RowAction { makeAdmin, removeAdmin, removeCollector, resetPassword }
