import 'package:flutter/material.dart';

import '../services/locale_controller.dart';

/// English / Filipino switch for the driver portal.
class LanguageToggle extends StatelessWidget {
  const LanguageToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final fil = LocaleController.instance.locale == AppLocale.filipino;
    return SegmentedButton<AppLocale>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: AppLocale.english, label: Text('English')),
        ButtonSegment(value: AppLocale.filipino, label: Text('Filipino')),
      ],
      selected: {fil ? AppLocale.filipino : AppLocale.english},
      onSelectionChanged: (s) => LocaleController.instance.setLocale(s.first),
    );
  }
}
