/// Web stand-in for tflite_flutter's [Interpreter] — see
/// tflite_interpreter.dart. Loading fails loudly so callers hit their
/// existing model-load error handling rather than silently matching nothing.
class Interpreter {
  Interpreter._();

  static Future<Interpreter> fromAsset(String assetName) async {
    throw UnsupportedError('TFLite face embedding is not available on web');
  }

  void run(Object input, Object output) {
    throw UnsupportedError('TFLite face embedding is not available on web');
  }

  void close() {}
}
