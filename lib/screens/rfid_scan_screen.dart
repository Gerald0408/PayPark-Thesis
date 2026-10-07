import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/rfid_receipt_flow.dart';
import '../widgets/toast.dart';

/// RFID scanning only — kept separate from manual Vehicle Entry so the
/// collector at the curb sees one big "tap the card" target and nothing
/// to type. Below it, today's card-scanned transactions so they can
/// confirm a tap went through.
class RfidScanScreen extends StatefulWidget {
  const RfidScanScreen({super.key, this.initialTag});

  /// A card already tapped before this screen opened (e.g. on the
  /// Dashboard, which routes every tap here) — processed right away as if
  /// it had been scanned on this screen.
  final String? initialTag;

  @override
  State<RfidScanScreen> createState() => _RfidScanScreenState();
}

class _RfidScanScreenState extends State<RfidScanScreen>
    with WidgetsBindingObserver {
  final _capture = TextEditingController();
  final _captureFocus = FocusNode();
  bool _busy = false;

  // Grabbed once — see RegistryScreen's _vehicles for why.
  late final Stream<List<ParkingTransaction>> _today =
      YosRepository.instance.todayTransactions();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _captureFocus.addListener(() => setState(() {}));
    final tag = widget.initialTag;
    if (tag != null && tag.trim().isNotEmpty) {
      // After the first frame, so the receipt sheet opens over this
      // screen rather than during its route transition's build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onScanned(tag);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _capture.dispose();
    _captureFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Bluetooth/permission popups can drop the reader's input connection —
    // see DashboardScreen._reclaimRfidFocus.
    if (state == AppLifecycleState.resumed) _reclaim();
  }

  void _reclaim() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      _captureFocus.unfocus();
      _captureFocus.requestFocus();
    });
  }

  /// A USB RFID reader acts as a keyboard: it "types" the tag, then Enter.
  Future<void> _onScanned(String raw) async {
    final tag = raw.trim();
    _capture.clear();
    if (tag.isEmpty) return;
    if (_busy) {
      Toast.warn(context,
          t('Finish the current receipt first.', 'Tapusin muna ang kasalukuyang resibo.'));
      return;
    }
    setState(() => _busy = true);
    try {
      await openReceiptForRfidTag(context, tag);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reclaim();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _captureFocus.hasFocus && !_busy;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Scan RFID Card', 'I-scan ang RFID Card'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              // Hidden capture field: keyboardType.none keeps the soft
              // keyboard away while keeping the input connection the OTG
              // reader's keystrokes need (readOnly would drop it — see
              // VehicleEntryScreen's old RFID field).
              Offstage(
                child: TextField(
                  controller: _capture,
                  focusNode: _captureFocus,
                  autofocus: true,
                  keyboardType: TextInputType.none,
                  onSubmitted: _onScanned,
                ),
              ),
              GlassCard(
                color: ready ? YosColors.sage : YosColors.surface,
                // Tapping the card re-arms the reader if focus was lost.
                onTap: _reclaim,
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
                child: Column(
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                      child: Icon(
                          _busy
                              ? Icons.hourglass_top_rounded
                              : Icons.contactless_rounded,
                          size: 72,
                          color: YosColors.inkLight),
                    ),
                    const SizedBox(height: 20),
                    Text(
                        _busy
                            ? t('Working on receipt…', 'Inihahanda ang resibo…')
                            : ready
                                ? t('Tap the card on the reader',
                                    'I-tap ang card sa reader')
                                : t('Tap here, then tap the card',
                                    'Pindutin dito, saka i-tap ang card'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 24)),
                    const SizedBox(height: 8),
                    Text(
                        t('The receipt opens by itself for registered cards.',
                            'Kusang bubukas ang resibo para sa rehistradong card.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(t("Today's Card Scans", 'Mga na-scan na card ngayon'),
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 18)),
              const SizedBox(height: 10),
              StreamBuilder<List<ParkingTransaction>>(
                stream: _today,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final scans = snap.data!
                      .where((tx) => tx.source == EntrySource.rfid)
                      .toList();
                  if (scans.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(t('No card scans yet today.',
                              'Wala pang na-scan na card ngayon.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: YosColors.sub, fontSize: 15)),
                    );
                  }
                  final total = scans.fold<double>(0, (s, tx) => s + tx.totalPaid);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          t('${scans.length} Scans · ₱${total.toStringAsFixed(0)}',
                              '${scans.length} scan · ₱${total.toStringAsFixed(0)}'),
                          style: TextStyle(
                              color: YosColors.sub,
                              fontSize: 14,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      for (final tx in scans)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _ScanRow(tx: tx),
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

class _ScanRow extends StatelessWidget {
  const _ScanRow({required this.tx});
  final ParkingTransaction tx;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: YosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YosColors.glassBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tx.plateNumber,
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 17)),
                Text(
                    '${tx.driverName} · ${DateFormat('hh:mm a').format(tx.timestamp)}'
                    ' · ${PaymentMethod.label(tx.paymentMethod)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: YosColors.sub, fontSize: 14)),
              ],
            ),
          ),
          Text('₱${tx.totalPaid.toStringAsFixed(0)}',
              style: TextStyle(
                  color: YosColors.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 18)),
        ],
      ),
    );
  }
}
