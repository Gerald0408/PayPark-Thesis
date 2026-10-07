import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/transaction.dart';
import '../services/blotter_service.dart';
import '../services/error_log_service.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/pdf_export_service.dart';
import '../services/printer_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_effects.dart';
import '../widgets/pdf_export_search_dialog.dart';
import '../widgets/shift_summary_dialog.dart';
import '../widgets/toast.dart';

/// Daily blotter: one page per day, like the barangay's paper logbook —
/// the day's collection summary (from that day's transactions) on top,
/// then every incident/complaint/violation/note collectors wrote down,
/// oldest first. Printable on the thermal printer or exportable as PDF
/// for the end-of-day turnover.
class BlotterScreen extends StatefulWidget {
  const BlotterScreen({super.key, this.isAdmin = false});

  /// Admins see only the whole day; collectors also get their own shift.
  final bool isAdmin;

  @override
  State<BlotterScreen> createState() => _BlotterScreenState();
}

class _BlotterScreenState extends State<BlotterScreen> {
  DateTime _day = _dateOnly(DateTime.now());
  late Stream<List<ParkingTransaction>> _txs;
  late Stream<List<BlotterEntry>> _entries;

  // Latest data the streams delivered — read by print/export so they use
  // exactly what's on screen.
  List<ParkingTransaction> _latestTxs = const [];
  List<BlotterEntry> _latestEntries = const [];
  bool _printing = false;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  bool get _isToday => _day == _dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _bindStreams();
  }

  /// Streams are created once per selected day, never inside build() —
  /// see RegistryScreen's _vehicles for why.
  void _bindStreams() {
    _txs = _isToday
        ? YosRepository.instance.todayTransactions()
        : Stream.fromFuture(YosRepository.instance.transactionsForDate(_day));
    _entries = BlotterService.instance.entriesFor(_day);
    _latestTxs = const [];
    _latestEntries = const [];
  }

  void _setDay(DateTime d) {
    final day = _dateOnly(d);
    if (day.isAfter(_dateOnly(DateTime.now()))) return;
    setState(() {
      _day = day;
      _bindStreams();
    });
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) _setDay(picked);
  }

  Future<void> _addEntry() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddEntrySheet(),
    );
    if (added == true && mounted) {
      if (!_isToday) _setDay(DateTime.now());
      Toast.success(context, t('Blotter entry saved', 'Naitala sa blotter'));
    }
  }

  String _categoryLabel(String c) => switch (c) {
        BlotterCategory.incident => t('Incident', 'Insidente'),
        BlotterCategory.complaint => t('Complaint', 'Reklamo'),
        BlotterCategory.violation => t('Violation', 'Paglabag'),
        _ => t('Note', 'Tala'),
      };

  /// Prints the day's blotter on the 58 mm thermal printer — summary
  /// first, then each entry.
  Future<void> _printThermal() async {
    final printer = PrinterService.instance;
    if (!printer.isConnected) {
      Toast.warn(context, t('Connect a printer first', 'Mag-connect muna ng printer'));
      return;
    }
    setState(() => _printing = true);
    try {
      final s = DailyCollectionSummary(_latestTxs);
      final timeFmt = DateFormat('hh:mm a');
      final lines = <String>[
        printer.pair('Date', DateFormat('MMM d, yyyy').format(_day)),
        printer.pair('Transactions', '${s.count}'),
        for (final e in s.byMethod.entries)
          printer.pair(PaymentMethod.label(e.key),
              'PHP ${e.value.toStringAsFixed(2)}'),
        if (s.overtime > 0)
          printer.pair('Incl. Extra Time', 'PHP ${s.overtime.toStringAsFixed(2)}'),
        if (s.discounts > 0)
          printer.pair('Discounts', '-PHP ${s.discounts.toStringAsFixed(2)}'),
        if (s.stillParked > 0) printer.pair('Still Parked', '${s.stillParked}'),
        printer.pair('TOTAL', 'PHP ${s.total.toStringAsFixed(2)}'),
        printer.divider,
        'BY COLLECTOR',
        for (final e in s.byCollector.entries)
          printer.pair('${e.key} (${e.value.$1})',
              'PHP ${e.value.$2.toStringAsFixed(2)}'),
        printer.divider,
        'BLOTTER ENTRIES (${_latestEntries.length})',
        if (_latestEntries.isEmpty) 'None recorded.',
        for (final e in _latestEntries) ...[
          '${timeFmt.format(e.timestamp)} ${_categoryLabel(e.category).toUpperCase()}',
          if (e.plateNumber != null) 'Plate: ${e.plateNumber}',
          e.description,
          '- ${e.collectorName ?? '-'}',
          '',
        ],
        '',
        'Prepared by: ${YosRepository.instance.currentUserName}',
        '',
        'Signature: ______________',
      ];
      await printer.printReport('DAILY BLOTTER', lines);
      HapticFeedback.heavyImpact();
      if (mounted) Toast.success(context, t('Blotter printed', 'Naka-print ang blotter'));
    } catch (e, st) {
      ErrorLogService.instance.record(e, st, where: 'print blotter');
      if (mounted) Toast.error(context, t('Print failed', 'Nabigo ang pag-print'));
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _exportPdf(PdfExportAction action) async {
    final s = DailyCollectionSummary(_latestTxs);
    final timeFmt = DateFormat('hh:mm a');
    try {
      final savedTo = await PdfExportService.exportTable(
        action: action,
        title: t('Daily Blotter', 'Pang-araw-araw na Blotter'),
        period: DateFormat('EEEE, MMM d, yyyy').format(_day),
        headers: [
          '#',
          t('Time', 'Oras'),
          t('Category', 'Uri'),
          t('Plate', 'Plaka'),
          t('Details', 'Detalye'),
          t('Recorded by', 'Itinala ni'),
        ],
        rows: [
          for (var i = 0; i < _latestEntries.length; i++)
            [
              '${i + 1}',
              timeFmt.format(_latestEntries[i].timestamp),
              _categoryLabel(_latestEntries[i].category),
              _latestEntries[i].plateNumber ?? '-',
              _latestEntries[i].description,
              _latestEntries[i].collectorName ?? '-',
            ],
        ],
        summary: [
          MapEntry(t('Transactions', 'Mga Transaksyon'), '${s.count}'),
          for (final e in s.byMethod.entries)
            MapEntry('${t('Collected via', 'Nakolekta sa')} ${PaymentMethod.label(e.key)}',
                'PHP ${e.value.toStringAsFixed(2)}'),
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
      ErrorLogService.instance.record(e, st, where: 'export blotter pdf');
      if (mounted) {
        Toast.error(context, t("Couldn't export PDF", 'Hindi na-export ang PDF'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(t('Daily Blotter', 'Blotter'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: t('Print on thermal printer', 'I-print sa thermal printer'),
            onPressed: _printing ? null : _printThermal,
            icon: const Icon(Icons.print_rounded),
          ),
          PopupMenuButton<PdfExportAction>(
            tooltip: t('Export PDF', 'I-export bilang PDF'),
            icon: const Icon(Icons.picture_as_pdf_rounded),
            onSelected: _exportPdf,
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addEntry,
        backgroundColor: YosColors.accent,
        foregroundColor: YosColors.onAccent,
        icon: const Icon(Icons.edit_note_rounded, size: 28),
        label: Text(t('Add Entry', 'Magtala'),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
            children: [
              _DayBar(
                day: _day,
                isToday: _isToday,
                onPrev: () => _setDay(_day.subtract(const Duration(days: 1))),
                onNext: _isToday
                    ? null
                    : () => _setDay(_day.add(const Duration(days: 1))),
                onPick: _pickDay,
              ),
              const SizedBox(height: 14),
              StreamBuilder<List<ParkingTransaction>>(
                key: ValueKey('tx-$_day'),
                stream: _txs,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return _InfoText(t("Couldn't load collections.",
                        'Hindi ma-load ang koleksyon.'));
                  }
                  if (!snap.hasData) {
                    return const SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator()));
                  }
                  _latestTxs = snap.data!;
                  final uid = FirebaseAuth.instance.currentUser?.uid;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Collectors see their own shift first — what they
                      // hand over — then the whole day.
                      if (!widget.isAdmin && uid != null) ...[
                        ShiftSummaryCard(
                            summary: ShiftSummary(snap.data!, uid)),
                        const SizedBox(height: 14),
                      ],
                      _SummaryCard(summary: DailyCollectionSummary(snap.data!)),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              Text(t('Logbook Entries', 'Mga tala sa logbook'),
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 18)),
              const SizedBox(height: 10),
              StreamBuilder<List<BlotterEntry>>(
                key: ValueKey('entries-$_day'),
                stream: _entries,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return _InfoText(t("Couldn't load blotter entries.",
                        'Hindi ma-load ang mga tala.'));
                  }
                  if (!snap.hasData) {
                    return const SizedBox(
                        height: 80,
                        child: Center(child: CircularProgressIndicator()));
                  }
                  _latestEntries = snap.data!;
                  if (snap.data!.isEmpty) {
                    return _InfoText(t(
                        'Nothing recorded for this day. Tap "Add Entry" to '
                            'write an incident, complaint, violation or note.',
                        'Walang naitala sa araw na ito. Pindutin ang '
                            '"Magtala" para magsulat ng insidente, reklamo, '
                            'paglabag o tala.'));
                  }
                  return Column(
                    children: [
                      for (final e in snap.data!)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _EntryCard(
                              entry: e, categoryLabel: _categoryLabel(e.category)),
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

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.isToday,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
  });

  final DateTime day;
  final bool isToday;
  final VoidCallback onPrev;
  final VoidCallback? onNext;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton.filledTonal(
          iconSize: 28,
          tooltip: t('Previous day', 'Nakaraang araw'),
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPick,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  Text(
                      isToday
                          ? t('Today', 'Ngayong araw')
                          : DateFormat('EEEE').format(day),
                      style: TextStyle(
                          color: YosColors.sub,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                  Text(DateFormat('MMM d, yyyy').format(day),
                      style: TextStyle(
                          color: YosColors.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 20)),
                ],
              ),
            ),
          ),
        ),
        IconButton.filledTonal(
          iconSize: 28,
          tooltip: t('Next day', 'Susunod na araw'),
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final DailyCollectionSummary summary;

  @override
  Widget build(BuildContext context) {
    Widget row(String label, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: bold ? YosColors.ink : YosColors.sub,
                        fontSize: bold ? 17 : 15,
                        fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
              ),
              Text(value,
                  style: TextStyle(
                      color: YosColors.ink,
                      fontSize: bold ? 19 : 15,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        );

    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('Collection Summary', 'Buod ng koleksyon'),
              style: TextStyle(
                  color: YosColors.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 18)),
          const SizedBox(height: 8),
          row(t('Transactions', 'Mga transaksyon'), '${summary.count}'),
          for (final e in summary.byMethod.entries)
            row(PaymentMethod.label(e.key), '₱${e.value.toStringAsFixed(2)}'),
          if (summary.overtime > 0)
            row(t('Of Which Extra Time', 'Kasama ang dagdag na oras'),
                '₱${summary.overtime.toStringAsFixed(2)}'),
          if (summary.discounts > 0)
            row(t('Points Discounts', 'Diskwento sa points'),
                '-₱${summary.discounts.toStringAsFixed(2)}'),
          if (summary.stillParked > 0)
            row(t('Still Parked', 'Nakaparada Pa'), '${summary.stillParked}'),
          const Divider(height: 18),
          row(t('Total Collected', 'Kabuuang nakolekta'),
              '₱${summary.total.toStringAsFixed(2)}',
              bold: true),
          if (summary.byCollector.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(t('By Collector', 'Bawat Kolektor'),
                style: TextStyle(
                    color: YosColors.sub,
                    fontWeight: FontWeight.w800,
                    fontSize: 14)),
            for (final e in summary.byCollector.entries)
              row('${e.key} · ${e.value.$1}',
                  '₱${e.value.$2.toStringAsFixed(2)}'),
          ],
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, required this.categoryLabel});
  final BlotterEntry entry;
  final String categoryLabel;

  Color get _color => switch (entry.category) {
        BlotterCategory.incident => YosColors.bad,
        BlotterCategory.violation => YosColors.warn,
        BlotterCategory.complaint => YosColors.accentDeep,
        _ => YosColors.sub,
      };

  @override
  Widget build(BuildContext context) {
    final zone = entry.zoneId == null
        ? null
        : kZones.where((z) => z.id == entry.zoneId).firstOrNull?.name ??
            entry.zoneId;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YosColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: _color, width: 5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(categoryLabel.toUpperCase(),
                  style: TextStyle(
                      color: _color,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 0.6)),
              const Spacer(),
              if (entry.pendingSync)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.sync_rounded, size: 16, color: YosColors.warn),
                ),
              Text(DateFormat('hh:mm a').format(entry.timestamp),
                  style: TextStyle(color: YosColors.sub, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 6),
          Text(entry.description,
              style: TextStyle(
                  color: YosColors.ink, fontSize: 16, height: 1.35)),
          const SizedBox(height: 8),
          Text(
              [
                if (entry.plateNumber != null) entry.plateNumber!,
                if (zone != null) zone,
                entry.collectorName ?? '-',
              ].join(' · '),
              style: TextStyle(
                  color: YosColors.sub,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _InfoText extends StatelessWidget {
  const _InfoText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(color: YosColors.sub, fontSize: 15)),
      );
}

/// New blotter entry form — category, what happened, optional plate and
/// zone. Saved append-only; there is no edit, matching a paper blotter.
class _AddEntrySheet extends StatefulWidget {
  const _AddEntrySheet();

  @override
  State<_AddEntrySheet> createState() => _AddEntrySheetState();
}

class _AddEntrySheetState extends State<_AddEntrySheet> {
  String _category = BlotterCategory.incident;
  String? _zoneId;
  final _description = TextEditingController();
  final _plate = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _description.dispose();
    _plate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_description.text.trim().length < 5) {
      Toast.warn(context,
          t('Describe what happened first.', 'Ilarawan muna ang nangyari.'));
      return;
    }
    setState(() => _saving = true);
    // Not awaited past the local write — Firestore queues it offline.
    BlotterService.instance
        .add(
          category: _category,
          description: _description.text,
          plateNumber: _plate.text,
          zoneId: _zoneId,
        )
        .catchError((Object e, StackTrace st) =>
            ErrorLogService.instance.record(e, st, where: 'add blotter entry'));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final labels = {
      BlotterCategory.incident: (t('Incident', 'Insidente'), Icons.report_rounded),
      BlotterCategory.complaint: (t('Complaint', 'Reklamo'), Icons.record_voice_over_rounded),
      BlotterCategory.violation: (t('Violation', 'Paglabag'), Icons.gavel_rounded),
      BlotterCategory.note: (t('Note', 'Tala'), Icons.sticky_note_2_rounded),
    };
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: YosColors.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('New Blotter Entry', 'Bagong tala sa blotter'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: YosColors.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 20)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final c in BlotterCategory.all)
                    ChoiceChip(
                      avatar: Icon(labels[c]!.$2, size: 20),
                      label: Text(labels[c]!.$1,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _description,
                minLines: 3,
                maxLines: 6,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(fontSize: 17),
                decoration: InputDecoration(
                  labelText: t('What happened?', 'Ano ang nangyari?'),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontSize: 17),
                decoration: InputDecoration(
                  labelText:
                      t('Plate Number (optional)', 'Plaka (opsyonal)'),
                  prefixIcon: const Icon(Icons.directions_car_rounded),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                value: _zoneId,
                decoration: InputDecoration(
                  labelText: t('Zone (optional)', 'Zone (opsyonal)'),
                  prefixIcon: const Icon(Icons.place_rounded),
                ),
                items: [
                  DropdownMenuItem(value: null, child: Text(t('None', 'Wala'))),
                  for (final z in kZones)
                    DropdownMenuItem(value: z.id, child: Text(z.name)),
                ],
                onChanged: (v) => setState(() => _zoneId = v),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_rounded),
                  label: Text(t('Save Entry', 'I-save ang tala'),
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
