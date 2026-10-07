import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// A GPS fix stamped on a receipt or points reward.
class GeoTag {
  const GeoTag({required this.lat, required this.lng, this.accuracy});

  final double lat;
  final double lng;

  /// Estimated error radius in metres, when the phone reports one.
  final double? accuracy;

  /// "14.59951,120.98422" — 5 decimals is about 1 m, and fits the 32-column
  /// receipt beside its label.
  String get short => '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

  String get mapsUrl => 'https://maps.google.com/?q=$short';
}

/// Gets the phone's location for geotagging receipts and rewards. Never
/// blocks or fails the transaction itself: no permission, location off, or
/// no fix within a few seconds all just mean "no geotag" (null).
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  GeoTag? _last;
  DateTime? _lastAt;

  /// A fix this recent is reused rather than asking the GPS again — the
  /// collector hasn't moved meaningfully between two cars at the curb.
  static const _reuseFor = Duration(minutes: 2);

  Future<GeoTag?> current() async {
    final at = _lastAt;
    if (_last != null && at != null && DateTime.now().difference(at) < _reuseFor) {
      return _last;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return _last;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return _last;
      }
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
      } catch (_) {
        // Weak GPS indoors/under a roof: fall back to the last fix the
        // phone itself remembers.
        pos = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      }
      if (pos == null) return _last;
      _last = GeoTag(lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy);
      _lastAt = DateTime.now();
      return _last;
    } catch (e) {
      debugPrint('[LocationService] no geotag: $e');
      return _last;
    }
  }
}
