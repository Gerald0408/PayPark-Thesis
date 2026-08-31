# PayPark — Android build fix

Package name used everywhere: `com.concepcion.payparking`

## 1. Copy files into `C:\dev\paypark`

Overwrite when prompted. Folder layout matches your project exactly.

| File in this bundle | Goes to |
|---|---|
| `android/app/google-services.json` | `android/app/google-services.json` |
| `android/app/build.gradle` | `android/app/build.gradle` |
| `android/app/proguard-rules.pro` | `android/app/proguard-rules.pro` |
| `android/app/src/main/AndroidManifest.xml` | same path |
| `android/app/src/debug/AndroidManifest.xml` | same path |
| `android/app/src/profile/AndroidManifest.xml` | same path |
| `android/app/src/main/kotlin/com/concepcion/payparking/MainActivity.kt` | same path |
| `android/build.gradle` | `android/build.gradle` |
| `android/settings.gradle` | `android/settings.gradle` |
| `android/gradle.properties` | `android/gradle.properties` |
| `android/gradle/wrapper/gradle-wrapper.properties` | same path |
| `lib/core/responsive.dart` | `lib/core/responsive.dart` |
| `lib/core/app_bootstrap.dart` | `lib/core/app_bootstrap.dart` |

## 2. Delete the old Kotlin folder

If `android/app/src/main/kotlin/com/example/` (or any other package folder)
still exists, DELETE it. Two MainActivity files = build failure.

Also delete `android/app/build.gradle.kts`, `android/build.gradle.kts` and
`android/settings.gradle.kts` if they exist — you cannot have both `.gradle`
and `.gradle.kts` versions of the same file.

## 3. Fix pubspec.yaml

Remove the invalid `config:` key. The `flutter:` section must look like this:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/
```

## 4. Patch lib/main.dart

```dart
import 'package:flutter/material.dart';
import 'core/app_bootstrap.dart';

void main() async {
  await AppBootstrap.run(const MyApp());   // replace MyApp with your root widget
}
```

Delete any existing `WidgetsFlutterBinding.ensureInitialized()` /
`Firebase.initializeApp()` lines in `main()` — AppBootstrap does both.

## 5. Patch lib/firebase_options.dart

Replace ONLY the `android` block (leave `web` alone so Chrome keeps working):

```dart
static const FirebaseOptions android = FirebaseOptions(
  apiKey: 'AIzaSyDv0jk5pWwPUbdZmuF6jBduA4882qGArZI',
  appId: '1:326618392344:android:a096ca1fe42ff4c08b206d',
  messagingSenderId: '326618392344',
  projectId: 'concepcion-pay-parking',
  storageBucket: 'concepcion-pay-parking.firebasestorage.app',
);
```

## 6. Build

```powershell
cd C:\dev\paypark
flutter clean
flutter pub get
cd android
.\gradlew clean
cd ..
flutter build apk --release
```

APK: `build\app\outputs\flutter-apk\app-release.apk`

Install that single file. Do NOT use `--split-per-abi` — it makes three
architecture-specific APKs and installing the wrong one is itself a cause of
"installs but won't open".

## 7. If it still fails

```powershell
adb install -r build\app\outputs\flutter-apk\app-release.apk
adb logcat -c
adb logcat -s flutter:V AndroidRuntime:E ActivityManager:E
```

Tap the icon, then read the output. The crash reason will be printed there.

## Responsive usage

```dart
import 'core/responsive.dart';

// Whole page
ResponsivePage(
  appBar: AppBar(title: const Text('Parking')),
  child: Column(children: [...]),
);

// Different layouts per size
Responsive(phone: PhoneView(), tablet: TabletView());

// Sizes that adapt
Text('Total', style: TextStyle(fontSize: context.sp(18)));
SizedBox(height: context.hp(2));
Padding(padding: context.pagePadding, child: ...);

// Grids that reflow instead of overflowing
GridView.builder(
  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 200,
    mainAxisSpacing: 12,
    crossAxisSpacing: 12,
  ),
  itemBuilder: ...,
);
```

Rules that eliminate most overflow errors on small phones:
- `Expanded` / `Flexible` inside `Row` and `Column`, never fixed widths
- `SingleChildScrollView` on any screen with a form
- `Wrap` instead of `Row` when children may not fit
- `SliverGridDelegateWithMaxCrossAxisExtent` instead of a fixed `crossAxisCount`
