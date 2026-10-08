import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/access_request.dart';
import '../models/transaction.dart';
import '../services/fee_settings_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/visit_flow.dart';
import 'access_requests_screen.dart';

/// How long [tx] has been parked past the hours the check-in fee covers
/// (when extra-hour charges start), or null while it's still within them.
Duration? overstayOf(ParkingTransaction tx, DateTime now) {
  final over = now.difference(tx.timestamp) -
      Duration(hours: FeeSettingsService.instance.baseHours);
  return over > Duration.zero ? over : null;
}

/// Dashboard bell's destination: every parked vehicle that has stayed past
/// its hours, longest overstay first, plus (admins only) pending access
/// requests. Tapping a vehicle opens its TIME OUT sheet.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.isAdmin});

  /// Only an admin can read access_requests (see firestore.rules).
  final bool isAdmin;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  // Grabbed once — see RegistryScreen's _vehicles for why.
  late final Stream<List<ParkingTransaction>> _parked =
      YosRepository.instance.parkedVehicles();
  late final Stream<List<AccessRequest>> _requests =
      YosRepository.instance.pendingAccessRequests();

  // Overstay grows with the clock, not with Firestore changes — rebuild
  // every minute so a vehicle shows up the moment its hours run out.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(minutes: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Notifications', 'Mga Abiso'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              if (widget.isAdmin)
                StreamBuilder<List<AccessRequest>>(
                  stream: _requests,
                  builder: (context, snap) {
                    final n = snap.data?.length ?? 0;
                    if (n == 0) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: _NoticeCard(
                        color: YosColors.warn,
                        icon: Icons.notifications_active_rounded,
                        title: t('$n Access Request${n == 1 ? '' : 's'}',
                            '$n Kahilingan sa Access'),
                        subtitle: t('Collectors asking for help signing in',
                            'Mga kolektor na humihingi ng tulong mag-sign in'),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AccessRequestsScreen())),
                      ),
                    );
                  },
                ),
              StreamBuilder<List<ParkingTransaction>>(
                stream: _parked,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Text(
                        t('Couldn\'t load parked vehicles: ${snap.error}',
                            'Hindi ma-load ang mga nakaparada: ${snap.error}'),
                        style: const TextStyle(color: YosColors.bad));
                  }
                  if (!snap.hasData) {
                    return Center(
                        child: CircularProgressIndicator(color: YosColors.ink));
                  }
                  final now = DateTime.now();
                  final over = [
                    for (final tx in snap.data!)
                      if (overstayOf(tx, now) case final d?) (tx, d),
                  ]..sort((a, b) => b.$2.compareTo(a.$2));
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          t('Overstaying Vehicles (${over.length})',
                              'Lumampas sa Oras (${over.length})'),
                          style: TextStyle(
                              color: YosColors.ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 17)),
                      const SizedBox(height: 4),
                      Text(
                          t('Parked longer than the hours chosen at Time In.',
                              'Nakaparada nang lampas sa napiling oras.'),
                          style: TextStyle(color: YosColors.sub, fontSize: 13)),
                      const SizedBox(height: 12),
                      if (over.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Text(
                              t('No vehicles over their time.',
                                  'Walang sasakyang lumampas sa oras.'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: YosColors.sub,
                                  fontWeight: FontWeight.w600)),
                        ),
                      for (final (i, (tx, d)) in over.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: PopIn(
                            delayMs: (i * 40).clamp(0, 400),
                            child: _NoticeCard(
                              color: YosColors.bad,
                              icon: Icons.timer_off_rounded,
                              title: '${tx.plateNumber} · ${tx.vehicleType}',
                              subtitle: t(
                                  'Over by ${formatStay(d)} · In ${DateFormat('h:mm a').format(tx.timestamp)} · First ${FeeSettingsService.instance.baseHours} Hours Covered',
                                  'Lampas ng ${formatStay(d)} · Pasok ${DateFormat('h:mm a').format(tx.timestamp)} · Sakop ang unang ${FeeSettingsService.instance.baseHours} oras'),
                              trailing: t('Time Out', 'Labas'),
                              onTap: () => runVisitFlow(context,
                                  open: tx, prepareCheckIn: () async => null),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: YosColors.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(color: YosColors.sub, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (trailing != null)
              Text(trailing!,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.w800, fontSize: 13))
            else
              Icon(Icons.chevron_right_rounded, color: YosColors.sub),
          ],
        ),
      ),
    );
  }
}
