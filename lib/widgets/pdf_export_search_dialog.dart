import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/locale_controller.dart';

/// Opened from a screen's "Export PDF" button — a live text search over
/// [items], independent of whatever filter/sort/search the screen behind
/// it currently has applied, so exporting a PDF doesn't require the
/// on-screen list to already be narrowed down to exactly what's wanted.
/// Confirming hands the matched subset to [onExport], which does the
/// actual PDF generation (and its own success/error toast) before this
/// dialog closes.
class PdfExportSearchDialog<T> extends StatefulWidget {
  const PdfExportSearchDialog({
    super.key,
    required this.items,
    required this.matches,
    required this.itemLabel,
    required this.onExport,
    this.hintText,
  });

  final List<T> items;
  final bool Function(T item, String query) matches;
  final String Function(T item) itemLabel;
  final Future<void> Function(List<T> matched) onExport;
  final String? hintText;

  @override
  State<PdfExportSearchDialog<T>> createState() =>
      _PdfExportSearchDialogState<T>();
}

class _PdfExportSearchDialogState<T> extends State<PdfExportSearchDialog<T>> {
  final _search = TextEditingController();
  bool _exporting = false;

  List<T> get _filtered {
    final q = _search.text.trim();
    if (q.isEmpty) return widget.items;
    return widget.items.where((i) => widget.matches(i, q)).toList();
  }

  Future<void> _export(List<T> matched) async {
    setState(() => _exporting = true);
    // onExport (the host screen's own PDF builder) already surfaces its own
    // success/error feedback, so this dialog just waits for it to finish
    // and closes either way rather than duplicating that messaging here.
    await widget.onExport(matched);
    if (mounted) Navigator.of(context).pop();
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
            TextField(
              controller: _search,
              autofocus: true,
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
                  ? t('1 matching record', '1 tumugmang tala')
                  : t('${matched.length} matching records',
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
            Material(
              color: matched.isEmpty
                  ? YosColors.sub.withOpacity(0.3)
                  : YosColors.accent,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: matched.isEmpty || _exporting
                    ? null
                    : () => _export(matched),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  alignment: Alignment.center,
                  child: _exporting
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: YosColors.onAccent),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.picture_as_pdf_rounded,
                                size: 18, color: YosColors.onAccent),
                            const SizedBox(width: 8),
                            Text(t('Export PDF', 'I-export bilang PDF'),
                                style: TextStyle(
                                    color: YosColors.onAccent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15)),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
