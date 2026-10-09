import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/blotter_service.dart';
import '../services/error_log_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/pdf_export_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/pdf_export_search_dialog.dart';
import '../widgets/toast.dart';

/// Daily / monthly / yearly collection report for admins: totals, payment
/// methods, vehicle types, collectors, and a per-day (month) or
/// per-month (year) breakdown — derived from transactions like the Daily
/// Blotter's summary, so the numbers always match Transaction Logs.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  /// Opens on today's report (per day).
  _Period _period = _Period.daily;
  DateTime _anchor = DateTime(
      DateTime.now().year, DateTime.now().month, DateTime.now().day);
  Future<List<ParkingTransaction>>? _load;

  bool get _yearly => _period == _Period.yearly;
  bool get _daily => _period == _Period.daily;

  DateTime get _start => switch (_period) {
        _Period.daily => DateTime(_anchor.year, _anchor.month, _anchor.day),
        _Period.monthly => DateTime(_anchor.year, _anchor.month),
        _Period.yearly => DateTime(_anchor.year),
      };
  DateTime get _end => switch (_period) {
        _Period.daily =>
          DateTime(_anchor.year, _anchor.month, _anchor.day + 1),
        _Period.monthly => DateTime(_anchor.year, _anchor.month + 1),
        _Period.yearly => DateTime(_anchor.year + 1),
      };

  String get _periodLabel => switch (_period) {
        _Period.daily => DateFormat('EEE, MMMM d, yyyy').format(_anchor),
        _Period.monthly => DateFormat('MMMM yyyy').format(_anchor),
        _Period.yearly => '${_anchor.year}',
      };

  bool get _isCurrent {
    final now = DateTime.now();
    return switch (_period) {
      _Period.daily => _anchor.year == now.year &&
          _anchor.month == now.month &&
          _anchor.day == now.day,
      _Period.monthly =>
        _anchor.year == now.year && _anchor.month == now.month,
      _Period.yearly => _anchor.year == now.year,
    };
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  // Block body, not `() => _load = ...`: an arrow closure returns the
  // assigned Future, and setState throws "callback argument returned a
  // Future" — which is what broke Collection Reports on open.
  void _reload() {
    final load = YosRepository.instance.transactionsBetween(_start, _end);
    setState(() {
      _load = load;
    });
  }

  void _step(int delta) {
    _anchor = switch (_period) {
      _Period.daily =>
        DateTime(_anchor.year, _anchor.month, _anchor.day + delta),
      _Period.monthly => DateTime(_anchor.year, _anchor.month + delta),
      _Period.yearly => DateTime(_anchor.year + delta, _anchor.month),
    };
    _reload();
  }

  /// Hour of day (daily), day of month (monthly) or month number
  /// (yearly) -> (count, total), in order.
  List<(String, int, double)> _breakdown(List<ParkingTransaction> txs) {
    final buckets = <int, (int, double)>{};
    for (final tx in txs) {
      final k = switch (_period) {
        _Period.daily => tx.timestamp.hour,
        _Period.monthly => tx.timestamp.day,
        _Period.yearly => tx.timestamp.month,
      };
      final (c, s) = buckets[k] ?? (0, 0.0);
      buckets[k] = (c + 1, s + tx.totalPaid);
    }
    final keys = buckets.keys.toList()..sort();
    return [
      for (final k in keys)
        (
          switch (_period) {
            _Period.daily => DateFormat('h a').format(DateTime(2000, 1, 1, k)),
            _Period.monthly => DateFormat('MMM d, EEE')
                .format(DateTime(_anchor.year, _anchor.month, k)),
            _Period.yearly => DateFormat('MMMM').format(DateTime(2000, k)),
          },
          buckets[k]!.$1,
          buckets[k]!.$2,
        ),
    ];
  }

  Map<String, (int, double)> _byType(List<ParkingTransaction> txs) {
    final out = <String, (int, double)>{};
    for (final tx in txs) {
      final (c, s) = out[tx.vehicleType] ?? (0, 0.0);
      out[tx.vehicleType] = (c + 1, s + tx.totalPaid);
    }
    return out;
  }

  static String _php(double v) => '₱${NumberFormat('#,##0.00').format(v)}';

  Future<void> _exportPdf(
      PdfExportAction action, List<ParkingTransaction> txs) async {
    final s = DailyCollectionSummary(txs);
    try {
      final savedTo = await PdfExportService.exportTable(
        action: action,
        title: switch (_period) {
          _Period.daily =>
            t('Daily Collection Report', 'Pang-araw-araw na Ulat ng Koleksyon'),
          _Period.monthly =>
            t('Monthly Collection Report', 'Buwanang Ulat ng Koleksyon'),
          _Period.yearly =>
            t('Yearly Collection Report', 'Taunang Ulat ng Koleksyon'),
        },
        period: _periodLabel,
        headers: [
          _yearly
              ? t('Month', 'Buwan')
              : _daily
                  ? t('Hour', 'Oras')
                  : t('Date', 'Petsa'),
          t('Vehicles', 'Sasakyan'),
          t('Collected', 'Nakolekta'),
        ],
        rows: [
          for (final (label, c, total) in _breakdown(txs))
            [label, '$c', 'PHP ${total.toStringAsFixed(2)}'],
        ],
        summary: [
          MapEntry(t('Transactions', 'Mga Transaksyon'), '${s.count}'),
          for (final e in s.byMethod.entries)
            MapEntry(
                '${t('Collected via', 'Nakolekta sa')} ${PaymentMethod.label(e.key)}',
                'PHP ${e.value.toStringAsFixed(2)}'),
          for (final e in _byType(txs).entries)
            MapEntry('${e.key} (${e.value.$1})',
                'PHP ${e.value.$2.toStringAsFixed(2)}'),
          for (final e in s.byCollector.entries)
            MapEntry('${e.key} (${e.value.$1})',
                'PHP ${e.value.$2.toStringAsFixed(2)}'),
          MapEntry(t('Total Collected', 'Kabuuang Nakolekta'),
              'PHP ${s.total.toStringAsFixed(2)}'),
        ],
      );
      if (mounted) {
        Toast.success(context, pdfExportDoneMessage(action, savedTo));
      }
    } catch (e, st) {
      ErrorLogService.instance.record(e, st, where: 'export report pdf');
      if (mounted) {
        Toast.error(
            context, t("Couldn't export PDF", 'Hindi na-export ang PDF'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ParkingTransaction>>(
      future: _load,
      builder: (context, snap) {
        final txs = snap.data;
        return Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: Text(t('Collection Reports', 'Ulat ng Koleksyon'),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              PopupMenuButton<PdfExportAction>(
                tooltip: t('Export PDF', 'I-export bilang PDF'),
                icon: const Icon(Icons.picture_as_pdf_rounded),
                enabled: txs != null,
                onSelected: (a) => _exportPdf(a, txs!),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: PdfExportAction.download,
                    child: ListTile(
                      leading: const Icon(Icons.download_rounded),
                      title: Text(t('Download PDF', 'I-download ang PDF')),
                    ),
                  ),
                  PopupMenuItem(
                    value: PdfExportAction.share,
                    child: ListTile(
                      leading: const Icon(Icons.share_rounded),
                      title: Text(t('Share PDF', 'Ibahagi ang PDF')),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: TouchGlowOverlay(
            child: SafeArea(
              child: RefreshIndicator(
                onRefresh: () async {
                  _reload();
                  // The error itself shows in the list below; the pull
                  // spinner just has to stop.
                  try {
                    await _load;
                  } catch (_) {}
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    // Full width, no check icon, one line per label — the
                    // icon squeezed "Monthly" until its "y" wrapped below.
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<_Period>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                              value: _Period.daily,
                              label: _SegmentLabel(
                                  t('Day', 'Araw'))),
                          ButtonSegment(
                              value: _Period.monthly,
                              label: _SegmentLabel(
                                  t('Month', 'Buwan'))),
                          ButtonSegment(
                              value: _Period.yearly,
                              label: _SegmentLabel(
                                  t('Year', 'Taon'))),
                        ],
                        selected: {_period},
                        onSelectionChanged: (v) {
                          _period = v.first;
                          // Jump back to the current day / month / year.
                          final now = DateTime.now();
                          _anchor = DateTime(now.year, now.month, now.day);
                          _reload();
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        IconButton(
                          tooltip: t('Previous', 'Nakaraan'),
                          onPressed: () => _step(-1),
                          icon:
                              const Icon(Icons.chevron_left_rounded, size: 30),
                        ),
                        Expanded(
                          child: Text(_periodLabel,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: YosColors.ink,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 20)),
                        ),
                        IconButton(
                          tooltip: t('Next', 'Susunod'),
                          onPressed: _isCurrent ? null : () => _step(1),
                          icon:
                              const Icon(Icons.chevron_right_rounded, size: 30),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (snap.hasError)
                      Text(
                          t("Couldn't load the report: ${snap.error}",
                              'Hindi ma-load ang ulat: ${snap.error}'),
                          style: const TextStyle(color: YosColors.bad))
                    else if (txs == null)
                      Padding(
                        padding: const EdgeInsets.all(40),
                        child: Center(
                            child: CircularProgressIndicator(
                                color: YosColors.ink)),
                      )
                    else if (txs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(40),
                        child: Text(
                            t('No collections in this period.',
                                'Walang koleksyon sa panahong ito.'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: YosColors.sub,
                                fontWeight: FontWeight.w600)),
                      )
                    else
                      ..._report(txs),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _report(List<ParkingTransaction> txs) {
    final s = DailyCollectionSummary(txs);
    final days = _breakdown(txs);
    return [
      PopIn(
        child: GlassCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Text(t('Total Collected', 'Kabuuang Nakolekta'),
                  style: TextStyle(
                      color: YosColors.sub,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
              const SizedBox(height: 4),
              Text(_php(s.total),
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 32)),
              const SizedBox(height: 4),
              Text(
                  _daily
                      ? t('${s.count} Vehicles · Average ${_php(s.count == 0 ? 0 : s.total / s.count)} Per Vehicle',
                          '${s.count} Sasakyan · Karaniwan ${_php(s.count == 0 ? 0 : s.total / s.count)} bawat sasakyan')
                      : t('${s.count} Vehicles · Average ${_php(s.total / days.length)} Per ${_yearly ? 'Month' : 'Day'}',
                          '${s.count} Sasakyan · Karaniwan ${_php(s.total / days.length)} bawat ${_yearly ? 'buwan' : 'araw'}'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: YosColors.sub, fontSize: 13)),
            ],
          ),
        ),
      ),
      const SizedBox(height: 14),
      _Section(
        title: t('Payment Methods', 'Paraan ng Bayad'),
        rows: [
          for (final e in s.byMethod.entries)
            (PaymentMethod.label(e.key), _php(e.value)),
          if (s.overtime > 0)
            (
              t('Of Which Extra Time', 'Kasama ang dagdag na oras'),
              _php(s.overtime)
            ),
          if (s.discounts > 0)
            (
              t('Points Discounts', 'Diskwento sa points'),
              '-${_php(s.discounts)}'
            ),
        ],
      ),
      _Section(
        title: t('By Vehicle Type', 'Bawat Uri ng Sasakyan'),
        rows: [
          for (final e in _byType(txs).entries)
            ('${e.key} · ${e.value.$1}', _php(e.value.$2)),
        ],
      ),
      _Section(
        title: t('By Collector', 'Bawat Kolektor'),
        rows: [
          for (final e in s.byCollector.entries)
            ('${e.key} · ${e.value.$1}', _php(e.value.$2)),
        ],
      ),
      _Section(
        title: switch (_period) {
          _Period.daily => t('By Hour', 'Bawat Oras'),
          _Period.monthly => t('By Day', 'Bawat Araw'),
          _Period.yearly => t('By Month', 'Bawat Buwan'),
        },
        rows: [
          for (final (label, c, total) in days) ('$label · $c', _php(total)),
        ],
      ),
    ];
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});
  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GlassCard(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    color: YosColors.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 17)),
            const SizedBox(height: 6),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label,
                          style: TextStyle(
                              color: YosColors.sub,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                    ),
                    Text(value,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A period-picker label that always stays on one line.
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700));
}

/// Which span Collection Reports covers.
enum _Period { daily, monthly, yearly }
