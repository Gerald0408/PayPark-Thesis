import 'package:flutter/material.dart';

import '../services/locale_controller.dart';

/// English / Filipino switch for the driver portal. [compact] is the
/// smaller version that fits in the top bar beside the title.
class LanguageToggle extends StatelessWidget {
  const LanguageToggle({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fil = LocaleController.instance.locale == AppLocale.filipino;
    return SegmentedButton<AppLocale>(
      showSelectedIcon: false,
      style: compact
          ? SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(fontSize: 13),
            )
          : null,
      segments: const [
        ButtonSegment(
            value: AppLocale.english,
            label: Text('English')),
        ButtonSegment(
            value: AppLocale.filipino,
            label: Text('Filipino')),
      ],
      selected: {fil ? AppLocale.filipino : AppLocale.english},
      onSelectionChanged: (s) => LocaleController.instance.setLocale(s.first),
    );
  }
}
