import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:light/light.dart';
import 'package:screen_brightness/screen_brightness.dart';

/// Ambient-light-driven brightness controller with smoothing + hysteresis.
///
/// Behavior:
/// - Android: reads the ambient light sensor via `light`. Every reading is
///   pushed into a rolling window; we act on the moving average to kill
///   noise. Mode flips only when the smoothed value stays past the
///   threshold for [_dwell] — this prevents flicker when the sensor
///   briefly spikes (e.g., a hand passing over the sensor).
/// - iOS / other: sensor unavailable → manual mode only.
///
/// Manual override:
/// - Calling [setManual] pins the mode for [_manualPin] seconds. Auto
///   resumes after that.
class LightController extends ChangeNotifier {
  LightController._();
  static final LightController instance = LightController._();

  // ---- Public state ----
 bool _sunMode = false;
bool get sunMode => _sunMode;

// 2. Update this line using defaultTargetPlatform:
bool get autoAvailable => defaultTargetPlatform == TargetPlatform.android;

bool _autoEnabled = true;
bool get autoEnabled => _autoEnabled;
double _smoothedLux = 200;
double get smoothedLux => _smoothedLux;
  // ---- Config ----
  static const int _windowSize = 10; // ~1s @ ~10Hz
  static const double _sunEnter = 2500; // lux — above this = sunny
  static const double _sunExit = 1500;  // hysteresis to prevent flicker
  static const Duration _dwell = Duration(milliseconds: 1500);
  static const Duration _manualPin = Duration(seconds: 30);

  // ---- Internal ----
  final Queue<double> _window = Queue();
  StreamSubscription<int>? _sub;
  Timer? _dwellTimer;
  Timer? _manualTimer;
  bool _initialized = false;

  /// Start listening. Safe to call multiple times.
  Future<void> start() async {
    if (_initialized) return;
    _initialized = true;
    if (!autoAvailable) return; // no sensor stream on iOS
    try {
      final light = Light();
      _sub = light.lightSensorStream.listen(_onLux, onError: (_) {
        // Sensor may not exist on this device — silently give up on auto.
      });
    } catch (_) {
      // Package failed to init — auto is unavailable on this device.
    }
  }

  void _onLux(int lux) {
    _window.addLast(lux.toDouble());
    while (_window.length > _windowSize) _window.removeFirst();
    _smoothedLux = _window.reduce((a, b) => a + b) / _window.length;

    // Notify listeners about the changing reading for UI display, but
    // only flip modes through the dwell check.
    notifyListeners();

    if (!_autoEnabled) return;
    final target = _sunMode ? _smoothedLux < _sunExit : _smoothedLux > _sunEnter;
    if (target) {
      _dwellTimer ??= Timer(_dwell, () {
        _dwellTimer = null;
        _applyMode(!_sunMode);
      });
    } else {
      _dwellTimer?.cancel();
      _dwellTimer = null;
    }
  }

  Future<void> _applyMode(bool sun) async {
    if (_sunMode == sun) return;
    _sunMode = sun;
    // Boost app-window brightness in sun mode; release in normal mode.
    try {
      if (sun) {
        await ScreenBrightness().setApplicationScreenBrightness(1.0);
      } else {
        await ScreenBrightness().resetApplicationScreenBrightness();
      }
    } catch (_) {
      // Brightness plugin may fail on desktop / web — mode change still
      // applies to the theme even without the brightness effect.
    }
    notifyListeners();
  }

  /// Manually force sun/normal. Auto resumes after [_manualPin].
  Future<void> setManual(bool sun) async {
    _autoEnabled = false;
    _manualTimer?.cancel();
    await _applyMode(sun);
    _manualTimer = Timer(_manualPin, () {
      _autoEnabled = true;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> toggleAuto() async {
    _autoEnabled = !_autoEnabled;
    _manualTimer?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _dwellTimer?.cancel();
    _manualTimer?.cancel();
    super.dispose();
  }
}
