import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import '../services/driver_account_service.dart';
import '../services/locale_controller.dart';
import '../services/points_settings_service.dart' show formatPoints;
import 'language_toggle.dart';

/// Driver portal home: total points, which discounts they can get, their
/// vehicles and their parking history — read-only, nothing here changes
/// money or points.
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  late final Future<DriverProfile?> _profile =
      DriverAccountService.instance.currentProfile();
  Stream<List<RegisteredVehicle>>? _vehicles;
  Stream<List<ParkingTransaction>>? _history;

  void _bind(DriverProfile p) {
    _vehicles ??= DriverAccountService.instance.vehicles(p.rfidTagKey);
    _history ??= DriverAccountService.instance.history(p.rfidTagKey);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DriverProfile?>(
      future: _profile,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            backgroundColor: YosColors.bg,
            body: Center(
                child: CircularProgressIndicator(color: YosColors.accent)),
          );
        }
        final profile = snap.data;
        if (profile == null) return const _AccessRevoked();
        _bind(profile);
        return Scaffold(
          backgroundColor: YosColors.bg,
          appBar: AppBar(
            title: Text(t('My PayPark', 'Aking PayPark'),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              PopupMenuButton<String>(
                tooltip: t('Menu', 'Menu'),
                icon: const Icon(Icons.more_vert_rounded, size: 28),
                onSelected: (v) {
                  if (v == 'pin') {
                    showDialog<void>(
                        context: context, builder: (_) => const _ChangePinDialog());
                  } else if (v == 'out') {
                    DriverAccountService.instance.signOut();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'pin',
                      child: Text(t('Change my PIN', 'Palitan ang PIN ko'),
                          style: const TextStyle(fontSize: 17))),
                  PopupMenuItem(
                      value: 'out',
                      child: Text(t('Sign out', 'Mag-sign out'),
                          style: const TextStyle(fontSize: 17))),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: StreamBuilder<List<RegisteredVehicle>>(
                  stream: _vehicles,
                  builder: (context, vSnap) {
                    final vehicles = vSnap.data ?? const <RegisteredVehicle>[];
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                  t('Hello, ${profile.name}!',
                                      'Kumusta, ${profile.name}!'),
                                  style: TextStyle(
                                      color: YosColors.ink,
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Align(
                            alignment: Alignment.centerLeft,
                            child: LanguageToggle()),
                        const SizedBox(height: 16),
                        if (vSnap.hasError)
                          _Notice(t("Couldn't load your vehicles.",
                              'Hindi ma-load ang iyong mga sasakyan.'))
                        else if (!vSnap.hasData)
                          const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: CircularProgressIndicator()))
                        else ...[
                          for (final v in vehicles) ...[
                            _VehicleCard(vehicle: v),
                            const SizedBox(height: 14),
                          ],
                          if (vehicles.isEmpty)
                            _Notice(t('No vehicles on this card yet.',
                                'Wala pang sasakyan sa card na ito.')),
                        ],
                        const SizedBox(height: 10),
                        _SectionTitle(
                            t('Parking history', 'Kasaysayan ng paradahan')),
                        StreamBuilder<List<ParkingTransaction>>(
                          stream: _history,
                          builder: (context, hSnap) {
                            if (hSnap.hasError) {
                              return _Notice(t("Couldn't load your history.",
                                  'Hindi ma-load ang iyong kasaysayan.'));
                            }
                            if (!hSnap.hasData) {
                              return const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Center(
                                      child: CircularProgressIndicator()));
                            }
                            final txs = hSnap.data!;
                            if (txs.isEmpty) {
                              return _Notice(t(
                                  'No parking visits yet. Visits paid with '
                                      'your card from now on show up here.',
                                  'Wala pang paradahan. Lalabas dito ang mga '
                                      'bayad gamit ang card mo simula ngayon.'));
                            }
                            return Column(children: [
                              for (final tx in txs) _HistoryRow(tx: tx),
                            ]);
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({required this.vehicle});
  final RegisteredVehicle vehicle;

  @override
  Widget build(BuildContext context) {
    final points = vehicle.points;
    final next = kRedemptionTiers
        .where((tier) => redemptionPointsCost(tier) > points)
        .firstOrNull;
    final best = kRedemptionTiers
        .where((tier) => redemptionPointsCost(tier) <= points)
        .lastOrNull;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: YosColors.surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: kSoftShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_car_rounded, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(vehicle.plateNumber,
                    style: TextStyle(
                        color: YosColors.ink,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
              ),
              Text(vehicle.vehicleType,
                  style: TextStyle(color: YosColors.sub, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 16),
          Text(t('Points', 'Points'),
              style: TextStyle(color: YosColors.sub, fontSize: 16)),
          Text(formatPoints(points),
              style: TextStyle(
                  color: YosColors.accentDeep,
                  fontSize: 44,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(
              best == null
                  ? t('Not enough points for a discount yet.',
                      'Kulang pa ang points para sa diskwento.')
                  : t('You can get up to $best% off your next parking.',
                      'Puwede kang makakuha ng hanggang $best% diskwento sa susunod mong paradahan.'),
              style: TextStyle(
                  color: YosColors.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          if (next != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                minHeight: 12,
                value: (points / redemptionPointsCost(next)).clamp(0, 1),
              ),
            ),
            const SizedBox(height: 6),
            Text(
                t(
                    '${formatPoints(redemptionPointsCost(next) - points)} more points for $next% off',
                    '${formatPoints(redemptionPointsCost(next) - points)} pang points para sa $next% diskwento'),
                style: TextStyle(color: YosColors.sub, fontSize: 15)),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tier in kRedemptionTiers)
                Chip(
                  avatar: Icon(
                      redemptionPointsCost(tier) <= points
                          ? Icons.check_circle_rounded
                          : Icons.lock_rounded,
                      size: 18),
                  label: Text(
                      '${formatPoints(redemptionPointsCost(tier))} pts = $tier%',
                      style: const TextStyle(fontSize: 15)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
              t(
                  'Show your card to the collector to use your points. '
                      '${vehicle.entryCount} visits'
                      '${vehicle.lastSeen != null ? ' · last ${DateFormat('MMM d, y').format(vehicle.lastSeen!)}' : ''}',
                  'Ipakita ang card sa collector para magamit ang points. '
                      '${vehicle.entryCount} pagbisita'
                      '${vehicle.lastSeen != null ? ' · huli ${DateFormat('MMM d, y').format(vehicle.lastSeen!)}' : ''}'),
              style: TextStyle(color: YosColors.sub, fontSize: 15)),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.tx});
  final ParkingTransaction tx;

  @override
  Widget build(BuildContext context) {
    final zone = kZones.where((z) => z.id == tx.zoneId).firstOrNull?.name ??
        tx.zoneId;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YosColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YosColors.glassBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(DateFormat('MMM d, y').format(tx.timestamp),
                    style: TextStyle(
                        color: YosColors.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                Text(
                    tx.timeOut != null
                        ? t(
                            'In ${DateFormat('hh:mm a').format(tx.timestamp)} · '
                                'Out ${DateFormat('hh:mm a').format(tx.timeOut!)} · '
                                '${formatStay(tx.stayDuration)}',
                            'Pasok ${DateFormat('hh:mm a').format(tx.timestamp)} · '
                                'Labas ${DateFormat('hh:mm a').format(tx.timeOut!)} · '
                                '${formatStay(tx.stayDuration)}')
                        : tx.awaitingCheckout
                            ? t(
                                'In ${DateFormat('hh:mm a').format(tx.timestamp)} · still parked',
                                'Pasok ${DateFormat('hh:mm a').format(tx.timestamp)} · nakaparada pa')
                            : t('In ${DateFormat('hh:mm a').format(tx.timestamp)}',
                                'Pasok ${DateFormat('hh:mm a').format(tx.timestamp)}'),
                    style: TextStyle(color: YosColors.ink, fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                    '${tx.plateNumber} · $zone · '
                    '${PaymentMethod.label(tx.paymentMethod)}',
                    style: TextStyle(color: YosColors.sub, fontSize: 15)),
                if (tx.extraFee > 0)
                  Text(
                      t('Includes ${tx.extraHours} Extra Hours · ₱${tx.extraFee.toStringAsFixed(0)}',
                          'Kasama ang ${tx.extraHours} dagdag na oras · ₱${tx.extraFee.toStringAsFixed(0)}'),
                      style: TextStyle(
                          color: YosColors.accentDeep,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                if (tx.discount > 0)
                  Text(
                      t('Saved ₱${tx.discount.toStringAsFixed(0)} with points',
                          'Nakatipid ng ₱${tx.discount.toStringAsFixed(0)} gamit ang points'),
                      style: TextStyle(
                          color: YosColors.good,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                Text('#${tx.trackingId}',
                    style: TextStyle(color: YosColors.sub, fontSize: 13)),
              ],
            ),
          ),
          Text('₱${tx.totalPaid.toStringAsFixed(0)}',
              style: TextStyle(
                  color: YosColors.ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: TextStyle(
                color: YosColors.ink,
                fontSize: 20,
                fontWeight: FontWeight.w800)),
      );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(color: YosColors.sub, fontSize: 17)),
      );
}

/// Shown when this account's PIN was replaced by a collector (a newer
/// account now owns the card) — the old session can't read anything.
class _AccessRevoked extends StatelessWidget {
  const _AccessRevoked();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YosColors.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_reset_rounded, size: 64, color: YosColors.sub),
              const SizedBox(height: 14),
              Text(
                  t('Your PIN was changed. Please sign in with your new PIN.',
                      'Napalitan ang PIN mo. Mag-sign in gamit ang bagong PIN.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: YosColors.ink, fontSize: 19)),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: DriverAccountService.instance.signOut,
                child: Text(t('Back to sign in', 'Bumalik sa sign in'),
                    style: const TextStyle(fontSize: 18)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog();

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_new.text != _confirm.text) {
      setState(() => _error =
          t("The new PINs don't match.", 'Hindi magkapareho ang mga bagong PIN.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DriverAccountService.instance
          .changeOwnPin(_current.text.trim(), _new.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('PIN changed.', 'Napalitan na ang PIN.'))));
    } on DriverLoginException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget field(TextEditingController c, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: c,
            enabled: !_busy,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: DriverAccountService.pinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 20, letterSpacing: 6),
            decoration: InputDecoration(labelText: label, counterText: ''),
          ),
        );
    return AlertDialog(
      title: Text(t('Change my PIN', 'Palitan ang PIN ko')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field(_current, t('Current PIN', 'Kasalukuyang PIN')),
            field(_new, t('New 6-digit PIN', 'Bagong 6-digit PIN')),
            field(_confirm, t('New PIN again', 'Bagong PIN ulit')),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(
                      color: YosColors.bad, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(t('Cancel', 'Kanselahin'))),
        FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(t('Save', 'I-save'))),
      ],
    );
  }
}
