import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Toast severity — controls color, icon, and haptic weight.
enum ToastKind { info, success, warn, error }

/// Global toast system.
///
/// Call `Toast.show(context, 'Saved')` from anywhere. A pill slides in from
/// the top-right, plays for ~2.6s, then slides out. Multiple toasts stack.
/// Tapping a toast dismisses it early.
///
/// Usage examples:
///   Toast.success(context, 'Entry logged');
///   Toast.info(context, 'Cancelled');
///   Toast.warn(context, 'Offline — saved locally');
///   Toast.error(context, 'Print failed');
class Toast {
  Toast._();

  static OverlayEntry? _entry;
  static final _ToastControllerState _bus = _ToastControllerState();

  static void _ensureOverlay(BuildContext context) {
    if (_entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(builder: (_) => _ToastHost(bus: _bus));
    overlay.insert(_entry!);
  }

  static void show(
    BuildContext context,
    String message, {
    ToastKind kind = ToastKind.info,
    Duration duration = const Duration(milliseconds: 2600),
    IconData? icon,
  }) {
    _ensureOverlay(context);
    _bus.push(_ToastItem(
      message: message,
      kind: kind,
      icon: icon ?? _defaultIcon(kind),
      duration: duration,
    ));
  }

  // Convenience helpers
  static void info(BuildContext c, String m) =>
      show(c, m, kind: ToastKind.info);
  static void success(BuildContext c, String m) =>
      show(c, m, kind: ToastKind.success);
  static void warn(BuildContext c, String m) =>
      show(c, m, kind: ToastKind.warn);
  static void error(BuildContext c, String m) =>
      show(c, m, kind: ToastKind.error);

  static IconData _defaultIcon(ToastKind k) => switch (k) {
        ToastKind.info => Icons.info_outline_rounded,
        ToastKind.success => Icons.check_circle_rounded,
        ToastKind.warn => Icons.warning_rounded,
        ToastKind.error => Icons.error_rounded,
      };
}

class _ToastItem {
  _ToastItem({
    required this.message,
    required this.kind,
    required this.icon,
    required this.duration,
  });

  final String message;
  final ToastKind kind;
  final IconData icon;
  final Duration duration;
  final int id = DateTime.now().microsecondsSinceEpoch;
}

/// Broadcast state so the overlay host rebuilds when items change.
class _ToastControllerState extends ChangeNotifier {
  final Queue<_ToastItem> items = Queue();

  void push(_ToastItem item) {
    items.addLast(item);
    notifyListeners();
  }

  void remove(int id) {
    items.removeWhere((i) => i.id == id);
    notifyListeners();
  }
}

class _ToastHost extends StatelessWidget {
  const _ToastHost({required this.bus});
  final _ToastControllerState bus;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: bus,
      builder: (_, __) {
        final list = bus.items.toList();
        return SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final item in list)
                    _ToastPill(
                      key: ValueKey(item.id),
                      item: item,
                      onGone: () => bus.remove(item.id),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ToastPill extends StatefulWidget {
  const _ToastPill({super.key, required this.item, required this.onGone});
  final _ToastItem item;
  final VoidCallback onGone;

  @override
  State<_ToastPill> createState() => _ToastPillState();
}

class _ToastPillState extends State<_ToastPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 340));
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _hide = Timer(widget.item.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    _hide?.cancel();
    if (!mounted) return;
    await _c.reverse();
    widget.onGone();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _c.dispose();
    super.dispose();
  }

  ({Color bg, Color fg}) _palette() {
    switch (widget.item.kind) {
      case ToastKind.success:
        return (bg: YosColors.mint, fg: YosColors.good);
      // Bg intentionally not from the green palette: it's tinted to match
      // its own fg (amber/red), same as the error case below — a caution
      // toast with a green background reads as "all good," which is the
      // opposite of what it's telling the collector.
      case ToastKind.warn:
        return (bg: const Color(0xFFFFF3D6), fg: YosColors.warn);
      case ToastKind.error:
        return (bg: const Color(0xFFFBEAE7), fg: YosColors.bad);
      case ToastKind.info:
        return (bg: YosColors.seafoam, fg: YosColors.ink);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _palette();
    final slide = Tween<Offset>(
      begin: const Offset(0.4, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
    final fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);

    // RepaintBoundary: this sits in the root Overlay, drawn on top of
    // whatever screen is currently showing, and animates in/out on every
    // single toast across the whole app — same "trace left behind"
    // reasoning as PopIn's matching comment in glow_effects.dart, so its
    // slide/fade repaints don't bleed into the screen content underneath.
    return RepaintBoundary(
      child: SlideTransition(
        position: slide,
        child: FadeTransition(
          opacity: fade,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onTap: _dismiss,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  constraints: const BoxConstraints(maxWidth: 340),
                  decoration: BoxDecoration(
                    color: YosColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: kSoftShadow,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                            color: p.bg, shape: BoxShape.circle),
                        child:
                            Icon(widget.item.icon, size: 18, color: p.fg),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.item.message,
                          style: TextStyle(
                            color: p.fg,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
