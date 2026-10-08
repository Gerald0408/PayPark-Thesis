import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/access_request.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/reset_password_dialog.dart';
import '../widgets/toast.dart';

/// Admin-only inbox for [AccessRequest]s (see YosRepository.
/// requestAccessReset) — each row is just a typed name and a time, since
/// there's no verified identity behind it.
///
/// "Grant password reset" is the actual lever available here — see
/// grantAccessRequestReset / YosRepository.resetCollectorPassword for how
/// the admin says which real collector a request maps to, then sets a
/// new username and passcode for them without a Cloud Functions backend.
///
/// The same reset is also reachable directly from CollectorsScreen (tap
/// any collector's row) for a locked-out collector who never filed a
/// request here, and from the dashboard's own pending-resets notification
/// (see DashboardScreen) — this screen is the full list, not the only
/// path in.
class AccessRequestsScreen extends StatefulWidget {
  const AccessRequestsScreen({super.key});

  @override
  State<AccessRequestsScreen> createState() => _AccessRequestsScreenState();
}

class _AccessRequestsScreenState extends State<AccessRequestsScreen> {
  // Grabbed once, not called fresh inside build() — a StatelessWidget
  // technically avoided the usual "setState hands StreamBuilder a new
  // Stream every rebuild" trigger, but not a rebuild forced some other
  // way (parent, hot reload, etc.), so this stays consistent with every
  // other list screen's `late final` pattern rather than relying on that.
  late final Stream<List<AccessRequest>> _requests =
      YosRepository.instance.pendingAccessRequests();

  Future<void> _dismiss(BuildContext context, AccessRequest r) async {
    try {
      await YosRepository.instance.resolveAccessRequest(r.id);
      if (context.mounted) {
        Toast.info(context, t('Dismissed', 'Na-dismiss'));
      }
    } catch (e) {
      if (context.mounted) {
        Toast.failure(context, t("Couldn't dismiss.", 'Hindi ma-dismiss.'), e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Access Requests', 'Mga Kahilingan sa Access'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<List<AccessRequest>>(
            stream: _requests,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                        t('Couldn\'t load requests: ${snap.error}',
                            'Hindi ma-load ang mga kahilingan: ${snap.error}'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: YosColors.bad)),
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
                  child: Text(t('No pending requests.', 'Walang nakabinbing kahilingan.'),
                      style: TextStyle(
                          color: YosColors.sub, fontWeight: FontWeight.w600)),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final r = list[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PopIn(
                      delayMs: (i * 40).clamp(0, 400),
                      child: GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                      color: YosColors.warn,
                                      borderRadius: BorderRadius.circular(14)),
                                  child: const Icon(
                                      Icons.notifications_active_rounded,
                                      color: Colors.white),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          r.name.isEmpty
                                              ? t('(no name given)', '(walang pangalan)')
                                              : r.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: YosColors.ink,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 15)),
                                      Text(
                                          t(
                                              'requested ${DateFormat('MMM d, y · h:mm a').format(r.requestedAt)}',
                                              'hiniling noong ${DateFormat('MMM d, y · h:mm a').format(r.requestedAt)}'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: YosColors.sub,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip:
                                      t('Dismiss without action', 'I-dismiss nang walang aksyon'),
                                  onPressed: () => _dismiss(context, r),
                                  icon: Icon(Icons.close_rounded,
                                      color: YosColors.sub),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: () =>
                                    grantAccessRequestReset(context, r),
                                icon: const Icon(Icons.lock_reset_rounded,
                                    size: 18),
                                label: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                      t('Grant password reset',
                                          'Payagan ang Pag-reset ng Password'),
                                      maxLines: 1),
                                ),
                              ),
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
