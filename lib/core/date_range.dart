import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/locale_controller.dart';

/// Shared date-range helpers for the transaction list's "Date range" filter
/// and the "Export PDF" dialog's period picker — both treat a
/// [DateTimeRange] from [showDateRangePicker] as whole calendar days, so
/// they live here once instead of drifting apart in two screens.

/// Today as a one-day range (midnight to midnight) — the PDF dialog's
/// default period, since a report is usually for the day it's generated.
DateTimeRange todayRange() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return DateTimeRange(start: today, end: today);
}

/// True when [ts] falls on any day from [range].start through
/// [range].end, inclusive. The picker hands back midnight for both ends,
/// so the end day's own entries need the +1 day upper bound to count.
bool inDateRange(DateTime ts, DateTimeRange range) {
  final start =
      DateTime(range.start.year, range.start.month, range.start.day);
  final endExclusive =
      DateTime(range.end.year, range.end.month, range.end.day + 1);
  return !ts.isBefore(start) && ts.isBefore(endExclusive);
}

/// "Sep 24, 2026" for a single day, "Sep 1, 2026 - Sep 24, 2026" otherwise.
String formatDateRange(DateTimeRange range) {
  final fmt = DateFormat('MMM d, yyyy');
  final start = fmt.format(range.start);
  final end = fmt.format(range.end);
  return start == end ? start : '$start - $end';
}

/// The "Period: …" line printed under a PDF export's title — "All dates"
/// when the export wasn't limited to a range.
String periodLabel(DateTimeRange? period) => t(
      'Period: ${period == null ? 'All dates' : formatDateRange(period)}',
      'Panahon: ${period == null ? 'Lahat ng petsa' : formatDateRange(period)}',
    );

/// Opens the platform date-range picker, capped at today (nothing to
/// report from the future). Returns null if the user cancels.
Future<DateTimeRange?> pickDateRange(BuildContext context,
    {DateTimeRange? initial}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return showDateRangePicker(
    context: context,
    firstDate: DateTime(2020),
    lastDate: today,
    initialDateRange: initial,
  );
}
