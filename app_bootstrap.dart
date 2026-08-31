import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';

/// Call this from main() instead of initialising Firebase inline.
/// If Firebase fails, the app still opens and shows the reason on screen
/// rather than dying at a blank white screen (the classic "installed but
/// won't open" symptom on a real phone).
class AppBootstrap {
  static String? initError;

  static Future<void> run(Widget app) async {
    WidgetsFlutterBinding.ensureInitialized();

    // Report Flutter framework errors instead of swallowing them in release.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('FlutterError: ${details.exceptionAsString()}');
    };

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
    } catch (e, s) {
      initError = e.toString();
      debugPrint('Firebase init failed: $e\n$s');
    }

    runApp(initError == null ? app : _StartupErrorApp(message: initError!));
  }
}

class _StartupErrorApp extends StatelessWidget {
  final String message;
  const _StartupErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Startup failed',
                  style:
                      TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  child: Text(message, textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
