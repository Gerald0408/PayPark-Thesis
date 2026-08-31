import 'package:flutter/material.dart';

/// Breakpoints tuned for phones first, then tablets/desktop.
class Breakpoints {
  static const double phone = 600;
  static const double tablet = 900;
  static const double desktop = 1200;
}

enum DeviceType { phone, tablet, desktop }

/// Usage:
///   Responsive(
///     phone: MyPhoneLayout(),
///     tablet: MyTabletLayout(),   // optional
///     desktop: MyDesktopLayout(), // optional
///   )
class Responsive extends StatelessWidget {
  final Widget phone;
  final Widget? tablet;
  final Widget? desktop;

  const Responsive({
    super.key,
    required this.phone,
    this.tablet,
    this.desktop,
  });

  static DeviceType typeOf(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= Breakpoints.desktop) return DeviceType.desktop;
    if (w >= Breakpoints.phone) return DeviceType.tablet;
    return DeviceType.phone;
  }

  static bool isPhone(BuildContext c) => typeOf(c) == DeviceType.phone;
  static bool isTablet(BuildContext c) => typeOf(c) == DeviceType.tablet;
  static bool isDesktop(BuildContext c) => typeOf(c) == DeviceType.desktop;

  /// Pick a value per device size without writing a ternary chain.
  static T value<T>(
    BuildContext context, {
    required T phone,
    T? tablet,
    T? desktop,
  }) {
    switch (typeOf(context)) {
      case DeviceType.desktop:
        return desktop ?? tablet ?? phone;
      case DeviceType.tablet:
        return tablet ?? phone;
      case DeviceType.phone:
        return phone;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= Breakpoints.desktop && desktop != null) {
          return desktop!;
        }
        if (constraints.maxWidth >= Breakpoints.phone && tablet != null) {
          return tablet!;
        }
        return phone;
      },
    );
  }
}

/// Scales a size against a 390pt-wide reference phone, clamped so text never
/// becomes unreadably small on a compact device or comically large on a tablet.
extension ResponsiveSize on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  double sp(double size) {
    final scale = (screenWidth / 390).clamp(0.85, 1.30);
    return size * scale;
  }

  double wp(double percent) => screenWidth * (percent / 100);
  double hp(double percent) => screenHeight * (percent / 100);

  EdgeInsets get pagePadding => EdgeInsets.symmetric(
        horizontal: Responsive.value<double>(this,
            phone: 16, tablet: 32, desktop: 64),
        vertical: 16,
      );
}

/// Drop-in page wrapper: safe area, scrolling, keyboard-aware, and a max
/// content width so the UI does not stretch into unreadable lines on tablets.
class ResponsivePage extends StatelessWidget {
  final Widget child;
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final Color? backgroundColor;
  final double maxContentWidth;
  final bool scrollable;

  const ResponsivePage({
    super.key,
    required this.child,
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.backgroundColor,
    this.maxContentWidth = 720,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth),
        child: Padding(padding: context.pagePadding, child: child),
      ),
    );

    return Scaffold(
      appBar: appBar,
      backgroundColor: backgroundColor,
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: scrollable
            ? LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(child: content),
                  ),
                ),
              )
            : content,
      ),
    );
  }
}
