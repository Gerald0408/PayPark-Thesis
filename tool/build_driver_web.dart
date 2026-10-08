// Builds the driver portal for Firebase Hosting with offline support:
//
//   dart run tool/build_driver_web.dart
//   firebase deploy --only hosting
//
// Same as `flutter build web -t lib/main_driver.dart --output
// build/driver_web`, plus:
//  - --no-web-resources-cdn, so the Flutter engine (CanvasKit) is served
//    from our own site instead of Google's CDN and can be cached offline;
//  - fills in build/driver_web/offline_sw.js with the list of files to
//    pre-cache and a fresh version, so phones pick up the new build.
import 'dart:io';

const _out = 'build/driver_web';

/// Firebase JS SDK modules FlutterFire loads — one per Firebase plugin in
/// pubspec.yaml ('app' is firebase_core). Update if a plugin is added.
const _firebaseServices = ['app', 'auth', 'firestore', 'storage', 'app-check'];

Future<void> main() async {
  final build = await Process.start(
    'flutter',
    [
      'build', 'web',
      '-t', 'lib/main_driver.dart',
      '--output', _out,
      '--no-web-resources-cdn',
    ],
    runInShell: true,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await build.exitCode;
  if (code != 0) exit(code);

  final root = Directory(_out);
  final files = <String>[];
  for (final e in root.listSync(recursive: true)) {
    if (e is! File) continue;
    final path = e.path
        .substring(root.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    if (_skip(path)) continue;
    files.add(path);
  }
  files.sort();

  // Firebase JS SDK files FlutterFire will import from the CDN — the
  // version is the one compiled into main.dart.js.
  final mainJs = File('$_out/main.dart.js').readAsStringSync();
  final sdk = RegExp(r'flutterfire_web_sdk_version[\s\S]{0,200}?"(\d+\.\d+\.\d+)"')
      .firstMatch(mainJs)
      ?.group(1);
  if (sdk == null) {
    stderr.writeln('Could not find the Firebase JS SDK version in '
        'main.dart.js — the app will only work offline from the 2nd visit.');
  }
  final cdn = [
    if (sdk != null)
      for (final s in _firebaseServices)
        'https://www.gstatic.com/firebasejs/$sdk/firebase-$s.js',
  ];

  final sw = File('$_out/offline_sw.js');
  final version = DateTime.now().millisecondsSinceEpoch.toString();
  String js(List<String> l) => '[\n${l.map((f) => "  '$f',").join('\n')}\n]';
  sw.writeAsStringSync(sw
      .readAsStringSync()
      .replaceFirst("'__VERSION__'", "'$version'")
      .replaceFirst('/*__PRECACHE__*/[]', js(files))
      .replaceFirst('/*__CDN_PRECACHE__*/[]', js(cdn)));

  stdout.writeln('\nOffline: ${files.length} files + ${cdn.length} Firebase '
      'SDK files pre-cached (version $version, Firebase JS ${sdk ?? '?'}). '
      'Deploy with: firebase deploy --only hosting');
}

/// Files a phone never needs offline: debug symbols, the service workers
/// themselves, engine variants this canvaskit/dart2js build doesn't load
/// (skwasm*, wimp, the WebParagraph CanvasKit), and the collector app's
/// big assets that the portal never shows (face model, intro video).
bool _skip(String path) =>
    path.endsWith('.symbols') ||
    path.endsWith('.tflite') ||
    path.endsWith('.mp4') ||
    path == '.last_build_id' ||
    path == 'assets/NOTICES' ||
    path == 'offline_sw.js' ||
    path == 'flutter_service_worker.js' ||
    path.startsWith('canvaskit/skwasm') ||
    path.startsWith('canvaskit/wimp') ||
    path.startsWith('canvaskit/webparagraph/');
