# YOS — Yard Operating System for Collectors

A cyber-industrial Flutter app for a single Barangay Collector working high-volume commercial parking zones (Savemore, Puregold). Replaces paper logs with offline-first Firestore logging, sub-60-second Bluetooth thermal receipts, and an immutable security audit trail.

## Feature map

| Spec module | Implementation |
|---|---|
| 1. Auth | `screens/intro_screen.dart` (animated intro) → `login_screen.dart` (Firebase email/password, animated validation) |
| 2. Command Dashboard | `dashboard_screen.dart` — glass stat cards with vertical odometer counters, sync badge, glowing "Log New Vehicle" action zone |
| 3. Fast Entry & Printing | `vehicle_entry_screen.dart` — plate auto-format, type selector, receipt preview drawer, single-tap ESC/POS print (`services/printer_service.dart`) |
| 4. Logs & Offline Engine | `logs_screen.dart` — instant search/filter, parallax depth scrolling; Firestore offline persistence with pending-write badges (`services/firestore_service.dart`) |
| 5. Audit Logs | `audit_screen.dart` + append-only `audit_logs` collection (`log_id, actor_id, action_type, description, timestamp`) |
| 6. Fee Matrix (read-only) | `fees_screen.dart` — ordinance rates locked in `core/constants.dart` + Firestore rules |
| 7. Zone Occupancy | `zones_screen.dart` — live per-zone counters with capacity bars |
| 8. Local Safeguards | `backup_screen.dart` + `services/backup_service.dart` — one-tap AES-256 encrypted snapshot |

Signature UI pieces live in `lib/widgets/`: `GlassCard` (BackdropFilter glass, tactile bounce), `OdometerCounter` (mechanical digit roll), `TouchGlowOverlay` (finger-follow neon aura), `BreathingGlowButton`, `SyncBadge`.

## Setup

### 1. Prerequisites
- Flutter 3.19+ (Dart ≥3.3)
- A Firebase project
- An Android device (Bluetooth printing targets Android; iOS works for everything except classic-Bluetooth printers)

### 2. Install dependencies
```bash
flutter pub get
```

### 3. Configure Firebase
```bash
dart pub global activate flutterfire_cli
flutterfire configure
```
This generates `lib/firebase_options.dart` (imported by `main.dart`).

Then in the Firebase console:
1. **Authentication → Sign-in method**: enable *Email/Password*.
2. **Authentication → Users**: create the single collector account and copy its UID.
3. **Firestore**: create the database, then paste `firestore.rules` into the Rules tab, replacing `REPLACE_WITH_COLLECTOR_UID` with the UID from step 2.
4. Create a composite index if prompted on first run (transactions ordered by `timestamp` with a range filter — Firestore's error message links directly to the one-click index creator).

### 4. Android permissions
Add to `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.INTERNET"/>
```
Set `minSdkVersion 21` (or higher) in `android/app/build.gradle`.

At runtime, request `Permission.bluetoothScan` and `Permission.bluetoothConnect` (the `permission_handler` package is already in pubspec) before the first printer scan on Android 12+.

### 5. Run
```bash
flutter run
```

## How the offline engine works

Firestore persistence is enabled with an unlimited cache (`firestore_service.dart`). Every write — transactions and audit events — lands in the local cache instantly and is queued for sync. The UI listens with `includeMetadataChanges: true`, so `doc.metadata.hasPendingWrites` drives the amber "Pending Sync" badges. `connectivity_plus` flips the global Live Syncing / Offline Mode badge and writes SYNC_ONLINE / SYNC_OFFLINE audit events on every transition. No manual queue code is needed; Firestore replays cached writes automatically when the connection returns.

## Printing notes

- Uses `flutter_pos_printer_platform_image_3` + `esc_pos_utils_plus`, generating raw ESC/POS bytes for 58mm paper (`printer_service.dart`). Switch to `PaperSize.mm80` for 80mm printers.
- The first print of a shift includes a one-time printer pick + pair; after that the connection persists (`autoConnect: true`), so the happy path is: submit form → preview drawer → one tap → paper. Well under 60 seconds.
- If the printer model garbles output, load a different `CapabilityProfile` (e.g., `CapabilityProfile.load(name: 'XP-N160I')`).

## Backup format

`yos_backup_<timestamp>.yosb` = `base64(IV)` + newline + `base64(AES-256-CBC ciphertext)` of a JSON snapshot. The key is derived (SHA-256) from the collector's UID, so a stolen file is unreadable without the account context. `BackupService.restoreSnapshot` decrypts it for recovery tooling.

## Compliance guardrails

- Fee rates are compile-time constants and Firestore rules only allow the `printed` flag to ever change on a transaction — no edits, no deletes.
- `audit_logs` is append-only at the rules level: `update, delete: if false`.
- Failed logins are audited without recording the attempted password.
