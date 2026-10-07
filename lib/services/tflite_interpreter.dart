// tflite_flutter depends on dart:ffi, which doesn't exist on web — so web
// builds get a stub Interpreter instead (Face ID embedding is unavailable
// there); every other platform gets the real package unchanged.
export 'tflite_interpreter_stub.dart'
    if (dart.library.ffi) 'package:tflite_flutter/tflite_flutter.dart';
