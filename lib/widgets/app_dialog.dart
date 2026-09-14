import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Shared confirm-dialog chrome — title + close (✕) in the header, a
/// message body, and one standalone rounded action button with its own
/// margin (not flush with the dialog's edges). Replaces the old pattern of
/// a title/content [AlertDialog] with a Cancel/Confirm [TextButton] row:
/// the ✕ now does what Cancel did (dismiss without acting), which is why
/// there's only ever one button here, not two.
///
/// Returns `true` if the action button was tapped, `false`/`null`
/// otherwise (✕, back button, or tapping the scrim) — same contract the
/// old two-button dialogs had, so call sites that already do
/// `if (confirmed != true) return;` don't need to change.
Future<bool?> showAppConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  IconData? confirmIcon,
  Color? confirmColor,
  bool barrierDismissible = true,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) => _AppConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      confirmIcon: confirmIcon,
      confirmColor: confirmColor,
    ),
  );
}

class _AppConfirmDialog extends StatelessWidget {
  const _AppConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.confirmIcon,
    this.confirmColor,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final IconData? confirmIcon;
  final Color? confirmColor;

  @override
  Widget build(BuildContext context) {
    final color = confirmColor ?? YosColors.accent;
    // Dark text/icon on a light confirmColor (the default accent, or a
    // pale tint like accentSoft), white on a dark/saturated one (bad,
    // warn) — a fixed onAccent would be wrong for either extreme, so this
    // picks per the actual color passed in instead.
    final onColor =
        color.computeLuminance() > 0.4 ? YosColors.inkLight : Colors.white;

    return Dialog(
      backgroundColor: YosColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: YosColors.ink)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: Icon(Icons.close_rounded, color: YosColors.sub),
                  tooltip: 'Cancel',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(message,
                  style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: YosColors.sub,
                      fontWeight: FontWeight.w500)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Material(
              color: color,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: () => Navigator.of(context).pop(true),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (confirmIcon != null) ...[
                        Icon(confirmIcon, size: 18, color: onColor),
                        const SizedBox(width: 8),
                      ],
                      Text(confirmLabel,
                          style: TextStyle(
                              color: onColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 15)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
