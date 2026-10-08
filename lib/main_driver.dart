import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'driver_portal/driver_home_screen.dart';
import 'driver_portal/driver_login_screen.dart';
import 'firebase_options.dart';
import 'services/locale_controller.dart';

/// Entry point of the driver portal — a separate, web-hosted app from the
/// collector app (lib/main.dart). Built with:
///
///   dart run tool/build_driver_web.dart
///
/// (flutter build web -t lib/main_driver.dart --output build/driver_web,
/// plus offline support — see that script)
///
/// and served by Firebase Hosting (see firebase.json). Imports only
/// web-safe code: no camera, ML, Bluetooth or RFID-reader plugins.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Keeps a copy of the driver's points and history in the browser, so
  // the portal still shows them offline (the app files themselves are
  // cached by web/offline_sw.js). Must be set before the first read.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  try {
    await LocaleController.instance.init();
  } catch (_) {}
  runApp(const DriverPortalApp());
}

class DriverPortalApp extends StatelessWidget {
  const DriverPortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LocaleController.instance,
      builder: (context, _) => MaterialApp(
        title: 'PayPark Driver',
        debugShowCheckedModeBanner: false,
        theme: YosTheme.current(),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return Scaffold(
                backgroundColor: YosColors.bg,
                body: Center(
                    child: CircularProgressIndicator(color: YosColors.accent)),
              );
            }
            // Non-const on purpose so a language switch rebuilds them —
            // see main.dart's RootShell/SplashScreen note.
            return snap.data == null
                ? DriverLoginScreen()
                : DriverHomeScreen(key: ValueKey(snap.data!.uid));
          },
        ),
      ),
    );
  }
}
