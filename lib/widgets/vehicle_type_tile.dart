import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';

/// Rounded badge showing a vehicle type's picture (its icon for a type
/// without one) — the leading badge in Fee Matrix and Registered
/// Vehicles rows. A bit wider than tall, since the pictures are.
class VehicleTypeBadge extends StatelessWidget {
  const VehicleTypeBadge(
      {super.key, required this.type, this.size = 52, this.color});

  final VehicleType type;

  /// Height; the width is 1.5 × this.
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final image = type.backgroundImage;
    return Container(
      width: size * 1.5,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: color ?? YosColors.mint,
          borderRadius: BorderRadius.circular(size * 0.3)),
      child: image == null
          ? Icon(type.icon, color: YosColors.ink, size: size * 0.5)
          : Image.asset(image, fit: BoxFit.contain),
    );
  }
}

/// Inside of a vehicle-type picker tile: the type's name (and optionally
/// its price) across the top, then its picture below — no icon, the
/// picture is the icon, and nothing runs behind the text.
class VehicleTypeTileContent extends StatelessWidget {
  const VehicleTypeTileContent({super.key, required this.type, this.price});

  final VehicleType type;
  final String? price;

  @override
  Widget build(BuildContext context) {
    final image = type.backgroundImage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Shrinks to fit rather than cutting off, so the price always
          // shows after the name.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: type.label,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w800)),
                if (price != null)
                  TextSpan(
                      text: '  $price',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w900)),
              ]),
              maxLines: 1,
              style: TextStyle(color: YosColors.inkLight),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: image == null
                ? Icon(type.icon, size: 36, color: YosColors.inkLight)
                : Image.asset(image, fit: BoxFit.contain),
          ),
        ],
      ),
    );
  }
}
