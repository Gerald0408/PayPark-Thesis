import 'package:flutter/material.dart';

import '../core/date_range.dart';
import '../core/theme.dart';
import '../services/locale_controller.dart';
import '../services/pdf_export_service.dart';

enum _PeriodMode { all, today, range }

/// Opened from a screen's "Export PDF" button — a live text search over
/// [items], independent of whatever filter/sort/search the screen behind
/// it currently has applied, so exporting a PDF doesn't require the
/// on-screen list to already be narrowed down to exactly what's wanted.
/// Confirming hands the matched subset to [onExport], which does the
/// actual PDF generation (and its own success/error toast) before this
/// dialog closes.
///
/// When [dateOf] is given, a Period dropdown (All dates / Today / Pick
/// dates…) also narrows the export by day. The chosen period is passed to
/// [onExport] (null = all dates) so the PDF can print it.
class PdfExportSearchDialog<T> extends StatefulWidget {
  const PdfExportSearchDialog({
    super.key,
    required this.items,
    required this.matches,
    required this.itemLabel,
    required this.onExport,
    this.dateOf,
    this.hintText,
  });

  final List<T> items;
  final bool Function(T item, String query) matches;
  final String Function(T item) itemLabel;
  final Future<void> Function(
          List<T> matched, DateTimeRange? period, PdfExportAction action)
      onExport;
  final DateTime Function(T item)? dateOf;
  final String? hintText;

  @override
  State<PdfExportSearchDialog<T>> createState() =>
      _PdfExportSearchDialogState<T>();
}

class _PdfExportSearchDialogState<T> extends State<PdfExportSearchDialog<T>> {
  final _search = TextEditingController();
  bool _exporting = false;

  /// Null = all dates, which is also where the Period dropdown starts.
  DateTimeRange? _period;

  List<T> get _filtered {
    final q = _search.text.trim();
    final period = _period;
    final dateOf = widget.dateOf;
    return widget.items.where((i) {
      if (period != null &&
          dateOf != null &&
          !inDateRange(dateOf(i), period)) {
        return false;
      }
      return q.isEmpty || widget.matches(i, q);
    }).toList();
  }

  _PeriodMode get _mode {
    final p = _period;
    if (p == null) return _PeriodMode.all;
    final today = todayRange();
    return DateUtils.isSameDay(p.start, today.start) &&
            DateUtils.isSameDay(p.end, today.end)
        ? _PeriodMode.today
        : _PeriodMode.range;
  }

  /// "Pick dates…" opens the calendar straight away (and again when
  /// re-selected, to change the days); cancelling it keeps the previous
  /// period, same as the transaction list's own Date range filter.
  Future<void> _onModeChanged(_PeriodMode? mode) async {
    switch (mode) {
      case null:
        return;
      case _PeriodMode.all:
        setState(() => _period = null);
      case _PeriodMode.today:
        setState(() => _period = todayRange());
      case _PeriodMode.range:
        final picked = await pickDateRange(context, initial: _period);
        if (picked != null && mounted) setState(() => _period = picked);
    }
  }

  Future<void> _export(List<T> matched, PdfExportAction action) async {
    setState(() => _exporting = true);
    // onExport (the host screen's own PDF builder) already surfaces its own
    // success/error feedback, so this dialog just waits for it to finish
    // and closes either way rather than duplicating that messaging here.
    await widget.onExport(matched, _period, action);
    if (mounted) Navigator.of(context).pop();
  }

  /// One dropdown (All dates / Today / Pick dates…), laid out like the
  /// transaction list's own "Filter" dropdown.
  Widget _periodPicker() {
    final mode = _mode;
    final options = [
      (_PeriodMode.all, t('All Dates', 'Lahat ng petsa')),
      (_PeriodMode.today, t('Today', 'Ngayon')),
      (_PeriodMode.range, t('Pick Dates…', 'Pumili ng petsa…')),
    ];
    // The picked days go on their own line below rather than into the
    // dropdown label — a two-date range is wider than the dialog has room
    // for next to the "Period" label, and overflowed the row.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _periodDropdown(mode, options),
          if (mode == _PeriodMode.range)
            InkWell(
              onTap: _exporting
                  ? null
                  : () => _onModeChanged(_PeriodMode.range),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.date_range_rounded,
                        size: 16, color: YosColors.accentDeep),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(formatDateRange(_period!),
                          style: TextStyle(
                              color: YosColors.ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _periodDropdown(
      _PeriodMode mode, List<(_PeriodMode, String)> options) {
    return Row(
      children: [
        Text(t('Period', 'Panahon'),
            style: TextStyle(
                color: YosColors.sub,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        DropdownButton<_PeriodMode>(
          value: mode,
          underline: const SizedBox.shrink(),
          isDense: true,
          items: [
            for (final (m, label) in options)
              DropdownMenuItem(value: m, child: Text(label)),
          ],
          // Only the selected label takes up room, so there's no wide gap
          // between a short label and the arrow.
          selectedItemBuilder: (_) => [
            for (final (m, label) in options)
              m == mode ? Text(label) : const SizedBox.shrink(),
          ],
          onChanged: _exporting ? null : _onModeChanged,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matched = _filtered;
    return Dialog(
      backgroundColor: YosColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(t('Export PDF', 'I-export bilang PDF'),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: YosColors.ink)),
                ),
                IconButton(
                  onPressed:
                      _exporting ? null : () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: YosColors.sub),
                  tooltip: t('Cancel', 'Kanselahin'),
                ),
              ],
            ),
            Text(
              t('Search for exactly what you want in the PDF.',
                  'Hanapin ang eksaktong gusto mong ilagay sa PDF.'),
              style: TextStyle(
                  color: YosColors.sub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (widget.dateOf != null) _periodPicker(),
            TextField(
              controller: _search,
              // Not when there's a Period picker above — the keyboard
              // popping up straight away would cover it, and picking the
              // day is usually the whole job; search is the extra step.
              autofocus: widget.dateOf == null,
              enabled: !_exporting,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: widget.hintText ?? t('Search…', 'Maghanap…'),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: t('Clear search', 'I-clear ang paghahanap'),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text(
              matched.length == 1
                  ? t('1 Matching Record', '1 tumugmang tala')
                  : t('${matched.length} Matching Records',
                      '${matched.length} tumugmang mga tala'),
              style: TextStyle(
                  color: YosColors.sub,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            // Flexible + a maxHeight cap, not a fixed-height ConstrainedBox
            // alone — the search field above autofocuses, which brings up
            // the keyboard immediately and can leave the dialog with well
            // under 240px of actual room. Flexible lets this list shrink
            // (and scroll internally, since it's already a ListView) to
            // whatever's actually left instead of overflowing the dialog —
            // same pattern as CollectorPickerDialog's own search list (see
            // widgets/reset_password_dialog.dart).
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: matched.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            t('No matches.', 'Walang tugma.'),
                            style: TextStyle(
                                color: YosColors.sub,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: matched.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: YosColors.glassBorder),
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Text(
                            widget.itemLabel(matched[i]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: YosColors.ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            // Download saves straight into the phone's Downloads folder;
            // Share opens the share sheet (Messenger, Gmail, print…).
            if (_exporting)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5)),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.download_rounded,
                      label: t('Download', 'I-download'),
                      filled: true,
                      onTap: matched.isEmpty
                          ? null
                          : () => _export(matched, PdfExportAction.download),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.share_rounded,
                      label: t('Share', 'Ibahagi'),
                      filled: false,
                      onTap: matched.isEmpty
                          ? null
                          : () => _export(matched, PdfExportAction.share),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Success message after [PdfExportService.exportTable] — for a download,
/// says where the file went ([savedTo] is exportTable's return value) so
/// the collector knows where to find it.
String pdfExportDoneMessage(PdfExportAction action, String? savedTo) =>
    action == PdfExportAction.download
        ? t('PDF saved to ${savedTo ?? 'Downloads'}',
            'Na-save ang PDF sa ${savedTo ?? 'Downloads'}')
        : t('PDF sent to share sheet', 'Naipadala ang PDF');

/// Pill button for the dialog's Download/Share row.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final bg = !enabled
        ? YosColors.sub.withOpacity(0.3)
        : filled
            ? YosColors.accent
            : YosColors.surface;
    final fg = filled || !enabled ? YosColors.onAccent : YosColors.ink;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          alignment: Alignment.center,
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: YosColors.accentDeep, width: 1.5),
                ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      color: fg, fontWeight: FontWeight.w800, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }
}
