import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/firestore_service.dart';

/// Gives the Super Admin their gold colors (see YosColors.superAdmin)
/// and everyone else plain navy, switching as people sign in and out.
///
/// Sits at the top of the app (MaterialApp.builder), so it's never
/// remounted by a sign-in or a screen change. On a change it repaints
/// every screen in place — every widget rebuilds with the new colors, but
/// nothing is reloaded or reset. (An earlier version rebuilt the whole
/// app instead, which remounted the dashboard and looped forever.)
class RoleColors extends StatefulWidget {
  const RoleColors({super.key, required this.child});

  final Widget child;

  @override
  State<RoleColors> createState() => _RoleColorsState();
}

class _RoleColorsState extends State<RoleColors> {
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = YosRepository.instance.currentUserIsSuperAdmin.listen(
      (isSuper) {
        if (YosColors.superAdmin.value == isSuper || !mounted) return;
        YosColors.superAdmin.value = isSuper;
        setState(() {}); // new Theme below
        _repaintEverything();
      },
      onError: (Object e) => debugPrint('RoleColors (ignored): $e'),
    );
  }

  /// Marks every widget below for a rebuild, so ones that read YosColors
  /// directly (not through Theme) pick up the new colors too.
  void _repaintEverything() {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // Theme rebuilt here (not only on MaterialApp) so buttons and other
  // themed widgets switch to gold as well.
  @override
  Widget build(BuildContext context) =>
      Theme(data: YosTheme.current(), child: widget.child);
}
