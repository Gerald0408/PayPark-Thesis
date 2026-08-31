import 'package:flutter/material.dart';

/// Breakpoints, phone-first.
class Breakpoints {
  static const double phone = 600;
  static const double tablet = 900;
  static const double desktop = 1200;
}

enum DeviceType { phone, tablet, desktop }

/// Reference width for text scaling: a 390 pt phone (iPhone 14 / mid Android).
const double _refWidth = 390;

extension ResponsiveContext on BuildContext {
  Size get _size => MediaQuery.sizeOf(this);

  double get screenWidth => _size.width;
  double get screenHeight => _size.height;

  DeviceType get deviceType {
    final w = screenWidth;
    if (w >= Breakpoints.desktop) return DeviceType.desktop;
    if (w >= Breakpoints.phone) return DeviceType.tablet;
    return DeviceType.phone;
  }

  bool get isPhone => deviceType == DeviceType.phone;
  bool get isTablet => deviceType == DeviceType.tablet;
  bool get isDesktop => deviceType == DeviceType.desktop;

  bool get isShortScreen => screenHeight < 640;

  /// Scales a font size against the reference width, clamped so text never
  /// becomes unreadable on a 320 pt device or absurd on a tablet.
  ///
  ///   Text('Total', style: TextStyle(fontSize: context.sp(18)))
  double sp(double size) {
    final factor = (screenWidth / _refWidth).clamp(0.82, 1.35);
    return size * factor;
  }

  /// Percentage of screen width / height.
  double wp(double percent) => screenWidth * (percent / 100);
  double hp(double percent) => screenHeight * (percent / 100);

  /// Horizontal page padding that widens on larger screens.
  EdgeInsets get pagePadding => EdgeInsets.symmetric(
        horizontal: pick<double>(phone: 16, tablet: 28, desktop: 48),
        vertical: pick<double>(phone: 12, tablet: 20, desktop: 24),
      );

  /// Gap unit that grows slightly with screen size.
  double get gap => pick<double>(phone: 12, tablet: 16, desktop: 20);

  /// Picks a value per device size without a ternary chain.
  T pick<T>({required T phone, T? tablet, T? desktop}) {
    switch (deviceType) {
      case DeviceType.desktop:
        return desktop ?? tablet ?? phone;
      case DeviceType.tablet:
        return tablet ?? phone;
      case DeviceType.phone:
        return phone;
    }
  }
}

/// Swaps whole layouts by width.
///
///   Responsive(phone: PhoneView(), tablet: TabletView())
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

/// Page wrapper: safe area, keyboard-aware scrolling, and a max content
/// width so lines never stretch unreadably wide on tablets or desktop.
class ResponsivePage extends StatelessWidget {
  final Widget child;
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final Color? backgroundColor;
  final double maxContentWidth;
  final bool scrollable;
  final EdgeInsets? padding;

  const ResponsivePage({
    super.key,
    required this.child,
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.backgroundColor,
    this.maxContentWidth = 720,
    this.scrollable = true,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth),
        child: Padding(
          padding: padding ?? context.pagePadding,
          child: child,
        ),
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
                    child: content,
                  ),
                ),
              )
            : content,
      ),
    );
  }
}

/// Wrap the app in this to make EVERY piece of text respect a sane scale,
/// including the user's own OS font-size setting.
///
/// In MaterialApp:
///   builder: (context, child) => ResponsiveTextScope(child: child!),
class ResponsiveTextScope extends StatelessWidget {
  final Widget child;
  final double minScale;
  final double maxScale;

  const ResponsiveTextScope({
    super.key,
    required this.child,
    this.minScale = 0.85,
    this.maxScale = 1.20,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    // Combines the OS accessibility setting with a width-based factor, then
    // clamps the result so oversized system fonts cannot break layouts.
    final widthFactor = (mq.size.width / _refWidth).clamp(0.90, 1.15);
    final combined = mq.textScaler.scale(1.0) * widthFactor;
    final clamped = combined.clamp(minScale, maxScale);

    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(clamped)),
      child: child,
    );
  }
}

/// Text that shrinks to fit rather than overflowing. Use for plate numbers,
/// totals, and anything on a fixed-width chip or card.
class FitText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int maxLines;
  final TextAlign textAlign;

  const FitText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: textAlign == TextAlign.center
          ? Alignment.center
          : Alignment.centerLeft,
      child: Text(
        text,
        style: style,
        maxLines: maxLines,
        textAlign: textAlign,
        softWrap: false,
      ),
    );
  }
}

/// Grid that reflows by available width instead of a fixed column count.
class ResponsiveGrid extends StatelessWidget {
  final List<Widget> children;
  final double maxItemWidth;
  final double spacing;
  final double childAspectRatio;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  const ResponsiveGrid({
    super.key,
    required this.children,
    this.maxItemWidth = 200,
    this.spacing = 12,
    this.childAspectRatio = 2.2,
    this.shrinkWrap = true,
    this.physics = const NeverScrollableScrollPhysics(),
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: physics,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxItemWidth,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: childAspectRatio,
      ),
      itemCount: children.length,
      itemBuilder: (_, i) => children[i],
    );
  }
}