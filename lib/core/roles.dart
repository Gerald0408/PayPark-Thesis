import 'package:flutter/material.dart';

import '../services/locale_controller.dart';
import 'theme.dart';

/// The three account roles — their label, icon and badge color (the
/// app's original navy / pale blue), plus [themeRole] for
/// YosColors.setRole (collectors' larger text).
enum AppRole {
  superAdmin(Icons.workspace_premium_rounded),
  admin(Icons.shield_rounded),
  collector(Icons.person_rounded);

  const AppRole(this.icon);

  final IconData icon;

  /// The app's original badge colors: deep navy for Super Admin and
  /// Admin, pale blue for Collectors.
  Color get color =>
      this == AppRole.collector ? YosColors.mint : YosColors.accentDeep;

  /// Icon / text color on top of [color].
  Color get onColor =>
      this == AppRole.collector ? YosColors.ink : YosColors.onAccent;

  static AppRole of({required bool isSuperAdmin, required bool isAdmin}) =>
      isSuperAdmin
          ? AppRole.superAdmin
          : isAdmin
              ? AppRole.admin
              : AppRole.collector;

  ThemeRole get themeRole => switch (this) {
        AppRole.superAdmin => ThemeRole.superAdmin,
        AppRole.admin => ThemeRole.admin,
        AppRole.collector => ThemeRole.collector,
      };

  String get label => switch (this) {
        AppRole.superAdmin => t('Super Admin', 'Super Admin'),
        AppRole.admin => t('Admin', 'Tagapangasiwa'),
        AppRole.collector => t('Collector', 'Kolektor'),
      };
}

/// Small rounded "Super Admin" / "Admin" / "Collector" pill in the role's
/// color.
class RolePill extends StatelessWidget {
  const RolePill(this.role, {super.key, this.fontSize = 11});

  final AppRole role;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
            color: role.color, borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(role.icon, size: fontSize + 2, color: role.onColor),
            const SizedBox(width: 4),
            Text(role.label,
                style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w800,
                    color: role.onColor)),
          ],
        ),
      );
}
