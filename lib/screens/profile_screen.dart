import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/collector.dart';
import '../services/firestore_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import 'collectors_screen.dart';

/// The "Profile" tab in RootShell's bottom navigation — the signed-in
/// collector's own account details (name, username, role, registered
/// date — exactly what was captured at registration), plus Collectors
/// (admin-only), the in-app admin's user-management screen. Self-service
/// "Change password" and "Face ID" screens used to live here too, but
/// with a real in-app admin now able to reset any account from
/// CollectorsScreen, they were dropped as redundant — a locked-out or
/// re-enrolling collector just asks the admin instead. Printer has its
/// own bottom-nav tab now (see RootShell), and Log out lives one level up
/// too (its own bottom-nav action, see RootShell._confirmLogout).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ProfileBody();
  }
}

String _initials(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

/// Split out from [ProfileScreen] purely so [currentCollectorProfile]'s
/// stream can be grabbed exactly once, in [State.initState] — see that
/// getter's own "fresh Stream per call, cache it yourself" doc comment.
/// Calling it directly as a StreamBuilder's `stream:` argument (the
/// previous shape of this screen) hands StreamBuilder a brand-new Stream
/// on every rebuild, which is exactly what causes Flutter's
/// "'_dependents.isEmpty': is not true" crash — the same pitfall
/// FeesScreen and RfidPointsScreen already avoid with this identical
/// `late final` pattern.
class _ProfileBody extends StatefulWidget {
  const _ProfileBody();

  @override
  State<_ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends State<_ProfileBody> {
  late final Stream<Collector?> _profile =
      YosRepository.instance.currentCollectorProfile;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Profile',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<Collector?>(
            stream: _profile,
            builder: (context, snap) {
              final me = snap.data;
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  if (snap.hasError)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Column(
                        children: [
                          const Icon(Icons.error_outline_rounded,
                              size: 40, color: YosColors.bad),
                          const SizedBox(height: 12),
                          Text('Couldn\'t load your profile: ${snap.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: YosColors.sub,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    )
                  else if (me == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                          child: CircularProgressIndicator(
                              color: YosColors.ink)),
                    )
                  else
                    PopIn(
                      child: GlassCard(
                        child: Row(
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                  color: me.isAdmin
                                      ? YosColors.accentDeep
                                      : YosColors.mint,
                                  borderRadius: BorderRadius.circular(18)),
                              alignment: Alignment.center,
                              child: Text(_initials(me.name),
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: me.isAdmin
                                          ? Colors.white
                                          : YosColors.ink)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(me.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 18)),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                            color: me.isAdmin
                                                ? YosColors.accentDeep
                                                : YosColors.seafoam,
                                            borderRadius:
                                                BorderRadius.circular(999)),
                                        child: Text(
                                            me.isAdmin ? 'Admin' : 'Collector',
                                            style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                                color: me.isAdmin
                                                    ? Colors.white
                                                    : YosColors.ink)),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                            'registered ${DateFormat('MMM d, y').format(me.createdAt)}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: YosColors.sub,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600)),
                                      ),
                                    ],
                                  ),
                                  // Null-safe: an account registered before
                                  // the passwordless sign-up form (see
                                  // RegisterScreen) simply has neither
                                  // field, so each row only shows up once
                                  // there's something to show.
                                  if (me.phone != null) ...[
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        const Icon(Icons.phone_outlined,
                                            size: 14, color: YosColors.sub),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(me.phone!,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color: YosColors.sub,
                                                  fontSize: 12,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (me.birthday != null) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const Icon(Icons.cake_outlined,
                                            size: 14, color: YosColors.sub),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                              DateFormat('MMM d, y')
                                                  .format(me.birthday!),
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color: YosColors.sub,
                                                  fontSize: 12,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // The only remaining action here (Collectors) is
                  // admin-only — skip the whole card for a regular
                  // collector instead of showing an empty white box.
                  if (me?.isAdmin == true) ...[
                    const SizedBox(height: 14),
                    PopIn(
                      delayMs: 60,
                      child: GlassCard(
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          leading: const Icon(Icons.groups_rounded,
                              color: YosColors.ink),
                          title: const Text('Collectors',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const CollectorsScreen())),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
