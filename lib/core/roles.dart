import 'package:flutter/material.dart';

import '../services/locale_controller.dart';
import 'theme.dart';

/// The three account roles and their colors — on role badges, avatar
/// circles and role pills, and (via [themeRole] / YosColors.setRole) as
/// the whole app's accent once that role is signed in.
enum AppRole {
  superAdmin(Color(0xFF8C6D0F), Icons.workspace_premium_rounded),
  admin(Color(0xFF334EAC), Icons.shield_rounded),
  collector(Color(0xFF17785D), Icons.person_rounded);

  const AppRole(this.color, this.icon);

  /// Gold (Super Admin), royal blue (Admin), teal green (Collector) —
  /// the same accents the whole app takes per role (YosColors), all
  /// readable with white on top.
  final Color color;
  final IconData icon;

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
            Icon(role.icon, size: fontSize + 2, color: Colors.white),
            const SizedBox(width: 4),
            Text(role.label,
                style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ],
        ),
      );
}
