import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';

/// Zone picker shared by VehicleEntryScreen's "Zone" and
/// RegisterVehicleScreen's "Default zone" — a fixed 2-column grid of equal-
/// width [ChoiceChip]s, not a plain [Wrap]. A [Wrap] sizes each chip to its
/// own label ("Savemore Hub" vs "Marson"), which is what made the two rows
/// of chips look like mismatched box sizes; this instead gives every chip
/// in a row the same share of the available width, on both screens, since
/// they both build this one widget now instead of duplicating the picker.
class ZoneChipGrid extends StatelessWidget {
  const ZoneChipGrid({
    super.key,
    required this.selectedZoneId,
    required this.onChanged,
  });

  final String selectedZoneId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < kZones.length; i += 2)
          Padding(
            padding:
                EdgeInsets.only(bottom: i + 2 < kZones.length ? 8 : 0),
            child: Row(
              children: [
                Expanded(child: _chip(kZones[i])),
                const SizedBox(width: 8),
                Expanded(
                  child: i + 1 < kZones.length
                      ? _chip(kZones[i + 1])
                      // Odd zone count's last row: an invisible spacer
                      // keeps that lone chip at the same half-width as
                      // every other one instead of stretching to fill
                      // the whole row.
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _chip(Zone z) => ChoiceChip(
        label: Center(child: Text(z.name)),
        selected: z.id == selectedZoneId,
        selectedColor: YosColors.sage,
        onSelected: (_) => onChanged(z.id),
      );
}
