import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../services/locale_controller.dart';
import '../services/points_settings_service.dart';
import '../services/registry_service.dart';
import '../services/vehicle_document_cache.dart';
import '../widgets/app_dialog.dart';
import '../widgets/driver_pin_dialog.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/glow_effects.dart';
import '../widgets/zone_chip_grid.dart';
import 'vehicle_attachment_screen.dart';
import 'vehicle_detail_screen.dart';

enum _SortMode { entriesDesc, nameAsc, newest }

/// Registry screen: searchable "Fleet Status"-style list of registered
/// vehicles, plus add/edit/delete.
class RegistryScreen extends StatefulWidget {
  const RegistryScreen({super.key, this.embedded = false});

  /// True when hosted as a tab inside [RootShell] — hides the back arrow.
  final bool embedded;

  @override
  State<RegistryScreen> createState() => _RegistryScreenState();
}

class _RegistryScreenState extends State<RegistryScreen> {
  final _search = TextEditingController();
  // Autofocused so a plug-and-play USB RFID reader (a USB-HID keyboard
  // that "types" the tag then Enter) lands its scan straight in the search
  // box — same approach as RfidPointsScreen's search field.
  final _searchFocus = FocusNode();
  _SortMode _sort = _SortMode.entriesDesc;
  bool _transferringPhotos = false;
  bool _fabOpen = false;

  // Grabbed once, not called fresh inside build() — the search box's own
  // setState on every keystroke would otherwise hand StreamBuilder a
  // brand-new Stream instance each time, which is what causes Flutter's
  // "'_dependents.isEmpty': is not true" crash. Same `late final` pattern
  // used across the other screens with a live Firestore stream.
  late final Stream<List<RegisteredVehicle>> _vehicles =
      VehicleRegistry.instance.all();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    // Self-heals any vehicle whose document photo only ever uploaded
    // locally (e.g. the initial upload failed over a weak signal in the
    // field) — this list is visited far more often than any one vehicle's
    // own detail screen, so it's a much more reliable place to retry than
    // waiting for someone to reopen that exact vehicle. One-shot per visit
    // (not a live subscription) — no need to re-sweep on every entry-count
    // update this same stream also fires on.
    _vehicles.first
        .then(VehicleRegistry.instance.backfillAllIfNeeded)
        .catchError((_) {});
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Enter in the search box — which is how a USB RFID reader ends a scan.
  /// Here a scan is only a search: the tag stays in the box to filter the
  /// list down to that vehicle (receipts are the Dashboard/Vehicle Entry's
  /// job). Selected so the next scan replaces it instead of appending.
  void _onSearchSubmitted(String _) {
    _search.selection =
        TextSelection(baseOffset: 0, extentOffset: _search.text.length);
    _searchFocus.requestFocus();
  }

  List<RegisteredVehicle> _apply(List<RegisteredVehicle> list) {
    final q = _search.text.trim().toUpperCase();
    // Tags compare by their normalized key (same as lookupByRfid), so a
    // reader that emits spaces/dashes still matches the stored tag.
    final tagQ = RegisteredVehicle.normalize(q);
    final out = (q.isEmpty
            ? list
            : list.where((v) =>
                v.plateNumber.toUpperCase().contains(q) ||
                v.driverName.toUpperCase().contains(q) ||
                (tagQ.isNotEmpty &&
                    v.rfidTag != null &&
                    RegisteredVehicle.normalize(v.rfidTag!).contains(tagQ))))
        .toList();
    switch (_sort) {
      case _SortMode.entriesDesc:
        out.sort((a, b) => b.entryCount.compareTo(a.entryCount));
        break;
      case _SortMode.nameAsc:
        out.sort((a, b) =>
            a.driverName.toUpperCase().compareTo(b.driverName.toUpperCase()));
        break;
      case _SortMode.newest:
        out.sort((a, b) => b.registeredAt.compareTo(a.registeredAt));
        break;
    }
    return out;
  }

  /// Manual cross-device photo carry, since this project's Firebase plan
  /// has no Storage: packs every document photo this device has cached
  /// (see VehicleDocumentCache) into a zip and hands it to the OS share
  /// sheet — Bluetooth, USB, a chat app, whatever the collector has on
  /// hand to physically get it to another phone.
  Future<void> _exportPhotos() async {
    setState(() => _transferringPhotos = true);
    try {
      final zipBytes = VehicleDocumentCache.instance.exportAll();
      if (zipBytes.isEmpty) {
        if (mounted) {
          Toast.warn(context,
              t('No photos on this device yet', 'Wala pang larawan sa device na ito'));
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/paypark_photos_$stamp.zip');
      await file.writeAsBytes(zipBytes);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        text: t('PayPark vehicle document photos',
            'Mga larawan ng dokumento ng sasakyan — PayPark'),
      );
    } catch (e) {
      if (mounted) {
        Toast.error(context, t("Couldn't export photos: $e", 'Hindi na-export: $e'));
      }
    } finally {
      if (mounted) setState(() => _transferringPhotos = false);
    }
  }

  /// The receiving half of [_exportPhotos] — picks a zip (saved from a
  /// share, downloaded, copied over USB, however it arrived) and restores
  /// every photo it contains into this device's own cache. Every
  /// RegisteredVehicle that already names one of these keys in its photo
  /// fields (synced for free via Firestore, from whichever device
  /// originally captured it) picks it up immediately — nothing else to
  /// reconcile.
  Future<void> _importPhotos() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _transferringPhotos = true);
    try {
      final bytes = await File(path).readAsBytes();
      final count = await VehicleDocumentCache.instance.importZip(bytes);
      if (mounted) {
        Toast.success(context,
            t('Imported $count photo(s)', 'Na-import ang $count na larawan'));
      }
    } catch (e) {
      if (mounted) {
        Toast.error(context, t("Couldn't import photos: $e", 'Hindi na-import: $e'));
      }
    } finally {
      if (mounted) setState(() => _transferringPhotos = false);
    }
  }

  /// Register/Export/Import as one speed-dial FAB instead of three
  /// separate controls competing for space — Register stays the single
  /// most-reached action (closest to the toggle once expanded), the two
  /// photo-transfer actions sit above it since they're rare, deliberate,
  /// one-time-per-device actions, not everyday taps.
  Widget _buildFab(BuildContext context) {
    if (_transferringPhotos) {
      return FloatingActionButton(
        heroTag: 'fab-toggle',
        backgroundColor: YosColors.accent,
        onPressed: null,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: YosColors.onAccent),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_fabOpen) ...[
          _fabOption(
            icon: Icons.download_rounded,
            label: t('Import Photos', 'I-import ang larawan'),
            onTap: _importPhotos,
          ),
          const SizedBox(height: 10),
          _fabOption(
            icon: Icons.ios_share_rounded,
            label: t('Export Photos', 'I-export ang larawan'),
            onTap: _exportPhotos,
          ),
          const SizedBox(height: 10),
          _fabOption(
            icon: Icons.directions_car_filled_rounded,
            label: t('Register Vehicle', 'Magrehistro ng sasakyan'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const RegisterVehicleScreen())),
          ),
          const SizedBox(height: 14),
        ],
        FloatingActionButton(
          heroTag: 'fab-toggle',
          backgroundColor: YosColors.accent,
          foregroundColor: YosColors.onAccent,
          tooltip: _fabOpen
              ? t('Close', 'Isara')
              : t('Register / Export / Import', 'Magrehistro / I-export / I-import'),
          onPressed: () => setState(() => _fabOpen = !_fabOpen),
          child: AnimatedRotation(
            // A "+" rotated 45° reads as an "x" — no separate close icon
            // needed, and nothing to cancel out.
            turns: _fabOpen ? 0.125 : 0,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.add_rounded),
          ),
        ),
      ],
    );
  }

  Widget _fabOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: YosColors.surface,
            borderRadius: BorderRadius.circular(10),
            boxShadow: kSoftShadow,
          ),
          child: Text(label,
              style: TextStyle(
                  color: YosColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
        ),
        const SizedBox(width: 10),
        FloatingActionButton.small(
          heroTag: label,
          backgroundColor: YosColors.accent,
          foregroundColor: YosColors.onAccent,
          onPressed: () {
            setState(() => _fabOpen = false);
            onTap();
          },
          child: Icon(icon),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded ? null : const BackButton(),
        title: Text(t('Registered Vehicles', 'Mga Nakarehistrong Sasakyan'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: _buildFab(context),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: StreamBuilder<List<RegisteredVehicle>>(
            stream: _vehicles,
            builder: (context, snap) {
              if (snap.hasError) {
                return const _ErrorState();
              }
              if (!snap.hasData) {
                return const _RegistrySkeleton();
              }
              final all = snap.data!;
              if (all.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.directions_car_filled_outlined,
                            size: 72, color: YosColors.sub),
                        const SizedBox(height: 16),
                        Text(
                          t('No vehicles registered yet.',
                              'Wala pang nakarehistrong sasakyan.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: YosColors.sub,
                              fontWeight: FontWeight.w700,
                              fontSize: 15),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t(
                              'Register a vehicle to make entries a one-tap flow.',
                              'Magrehistro ng sasakyan para maging one-tap ang pag-entry.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: YosColors.sub, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                );
              }

              final list = _apply(all);
              final totalEntries = all.fold<int>(0, (s, v) => s + v.entryCount);
              final weekAgo = DateTime.now().subtract(const Duration(days: 7));
              final newThisWeek =
                  all.where((v) => v.registeredAt.isAfter(weekAgo)).length;
              final frequent = all.where((v) => v.entryCount >= 15).length;

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _search,
                                focusNode: _searchFocus,
                                autofocus: true,
                                textInputAction: TextInputAction.search,
                                onSubmitted: _onSearchSubmitted,
                                decoration: InputDecoration(
                                  hintText: t('Search vehicle, driver or RFID',
                                      'Maghanap ng sasakyan, driver o RFID'),
                                  prefixIcon: const Icon(Icons.search_rounded),
                                  suffixIcon: _search.text.isEmpty
                                      ? null
                                      : IconButton(
                                          icon: const Icon(Icons.close_rounded),
                                          tooltip: t('Clear search', 'I-clear ang search'),
                                          onPressed: () => _search.clear(),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            _SortButton(
                              value: _sort,
                              onChanged: (m) => setState(() => _sort = m),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _StatStrip(
                          total: all.length,
                          entries: totalEntries,
                          frequent: frequent,
                          newThisWeek: newThisWeek,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: list.isEmpty
                        ? Center(
                            child: Text(t('No matches.', 'Walang nahanap.'),
                                style: TextStyle(
                                    color: YosColors.sub,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)))
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
                            itemCount: list.length,
                            itemBuilder: (_, i) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: PopIn(
                                delayMs: (i * 40).clamp(0, 400),
                                child: _RegCard(vehicle: list[i], index: i),
                              ),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Compact icon-triggered sort menu — same three options as before, but
/// as a fixed 44×44 button instead of an always-expanded dropdown row.
/// Frees width back to the search field and can't get clipped on a
/// narrow device the way a label-bearing dropdown could.
class _SortButton extends StatelessWidget {
  const _SortButton({required this.value, required this.onChanged});
  final _SortMode value;
  final ValueChanged<_SortMode> onChanged;

  static Map<_SortMode, String> get _labels => {
        _SortMode.entriesDesc: t('Most Entries', 'Pinakamaraming Entry'),
        _SortMode.nameAsc: t('Driver Name', 'Pangalan ng Driver'),
        _SortMode.newest: t('Newest First', 'Pinakabago'),
      };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${t('Sort vehicles', 'Isort ang mga sasakyan')}: ${_labels[value]}',
      button: true,
      child: ExcludeSemantics(
        child: PopupMenuButton<_SortMode>(
          color: YosColors.surfaceHigh,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          onSelected: (m) {
            HapticFeedback.selectionClick();
            onChanged(m);
          },
          itemBuilder: (context) => [
            for (final entry in _labels.entries)
              PopupMenuItem(
                value: entry.key,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 22,
                      child: entry.key == value
                          ? Icon(Icons.check_rounded,
                              size: 18, color: YosColors.accent)
                          : null,
                    ),
                    const SizedBox(width: 6),
                    Text(entry.value,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: YosColors.ink)),
                  ],
                ),
              ),
          ],
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: YosColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: YosColors.glassBorder),
            ),
            child: Icon(Icons.sort_rounded, color: YosColors.ink, size: 20),
          ),
        ),
      ),
    );
  }
}

class _StatStrip extends StatelessWidget {
  const _StatStrip({
    required this.total,
    required this.entries,
    required this.frequent,
    required this.newThisWeek,
  });
  final int total;
  final int entries;
  final int frequent;
  final int newThisWeek;

  @override
  Widget build(BuildContext context) {
    final stats = [
      ('$total', t('Total Vehicles', 'Kabuuang Sasakyan')),
      ('$entries', t('Total Entries', 'Kabuuang Entry')),
      ('$frequent', t('Frequent', 'Madalas')),
      ('$newThisWeek', t('New This Week', 'Bago Ngayong Linggo')),
    ];
    // Deliberately no card here: this is a plain summary strip, not a
    // content row, and boxing it made it compete visually with the list
    // below it. The hairline dividers alone are enough separation.
    return Row(
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0)
            Container(
                width: 1,
                height: 30,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: YosColors.glassBorder),
          Expanded(
            child: Semantics(
              label: '${stats[i].$1} ${stats[i].$2}',
              child: ExcludeSemantics(
                child: Column(
                  children: [
                    Text(stats[i].$1,
                        style: TextStyle(
                            color: YosColors.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 20)),
                    const SizedBox(height: 3),
                    Text(stats[i].$2,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: YosColors.sub,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _RegCard extends StatelessWidget {
  const _RegCard({required this.vehicle, required this.index});
  final RegisteredVehicle vehicle;
  final int index;

  Color get _tierColor {
    if (vehicle.entryCount >= 15) return YosColors.healthHigh;
    if (vehicle.entryCount >= 5) return YosColors.healthMid;
    return YosColors.healthLow;
  }

  static String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  static String _agoLabel(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return t('just now', 'ngayon lang');
    if (diff.inMinutes < 60) {
      return t('${diff.inMinutes}m ago', '${diff.inMinutes}m ang nakaraan');
    }
    if (diff.inHours < 24) {
      return t('${diff.inHours}h ago', '${diff.inHours}h ang nakaraan');
    }
    if (diff.inDays < 30) {
      return t('${diff.inDays}d ago', '${diff.inDays}d ang nakaraan');
    }
    return DateFormat('MMM d').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final vt = VehicleType.fromLabel(vehicle.vehicleType);
    final zone = kZones.firstWhere((z) => z.id == vehicle.defaultZoneId,
        orElse: () => kZones.first);
    final tier = _tierColor;
    final ago = _agoLabel(vehicle.lastSeen ?? vehicle.registeredAt);

    return Container(
      decoration: BoxDecoration(
        color: YosColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YosColors.glassBorder),
      ),
      // Material+InkWell instead of a bare GestureDetector: this row
      // navigates to the edit screen, so it needs the same tap feedback
      // every other actionable surface in the app gives — a visible
      // ripple plus a selection haptic, not a silent tap.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => VehicleDetailScreen(vehicle: vehicle)));
            },
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ExcludeSemantics(
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                                color: pastelAt(index),
                                borderRadius: BorderRadius.circular(14)),
                            child:
                                Icon(vt.icon, color: YosColors.ink, size: 22),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(vehicle.plateNumber,
                                  style: TextStyle(
                                      color: YosColors.ink,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      letterSpacing: 1.0)),
                              Text('${vt.label} · ${zone.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: YosColors.sub,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('${vehicle.entryCount}',
                                style: TextStyle(
                                    color: tier,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18)),
                            Text(t('entries', 'entry'),
                                style: TextStyle(
                                    color: YosColors.sub,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(width: 4),
                        Semantics(
                          label: '${t('Edit', 'I-edit')} ${vehicle.plateNumber}',
                          button: true,
                          child: ExcludeSemantics(
                            child: IconButton(
                              tooltip: t('Edit', 'I-edit'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => RegisterVehicleScreen(
                                        existing: vehicle)));
                              },
                              icon: Icon(Icons.edit_outlined,
                                  color: YosColors.sub, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(height: 1, color: YosColors.glassBorder),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ExcludeSemantics(
                          child: CircleAvatar(
                            radius: 11,
                            backgroundColor: YosColors.surfaceHigh,
                            child: MediaQuery.withNoTextScaling(
                              child: Text(_initials(vehicle.driverName),
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: YosColors.ink)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(vehicle.driverName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: YosColors.ink)),
                        ),
                        Text(ago,
                            style: TextStyle(
                                color: YosColors.sub,
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading placeholder shaped like the real layout (search row, sort
/// button, stat strip, four list rows) so nothing reflows when the first
/// snapshot arrives.
class _RegistrySkeleton extends StatelessWidget {
  const _RegistrySkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Row(
          children: [
            const Expanded(child: SkeletonBox(height: 56, borderRadius: 12)),
            const SizedBox(width: 10),
            SkeletonBox(width: 44, height: 44, borderRadius: 12),
          ],
        ),
        const SizedBox(height: 14),
        const SkeletonBox(height: 46, borderRadius: 12),
        const SizedBox(height: 16),
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SkeletonBox(height: 110, borderRadius: 16),
          ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, size: 56, color: YosColors.sub),
            const SizedBox(height: 16),
            Text(
              t("Couldn't load the registry.", 'Hindi ma-load ang registry.'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: YosColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 17),
            ),
            const SizedBox(height: 6),
            Text(
              t(
                  'Check your connection — this list updates automatically '
                      'once you\'re back online.',
                  'Suriin ang iyong koneksyon — awtomatikong mag-a-update '
                      'ang listahang ito once online ka na ulit.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: YosColors.sub, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

/// Register / edit a vehicle.
class RegisterVehicleScreen extends StatefulWidget {
  const RegisterVehicleScreen({super.key, this.existing, this.initialPlate});
  final RegisteredVehicle? existing;
  final String? initialPlate; // used when the scanner found a new plate

  @override
  State<RegisterVehicleScreen> createState() => _RegisterVehicleScreenState();
}

class _RegisterVehicleScreenState extends State<RegisterVehicleScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _driver;
  late final TextEditingController _plate;
  late final TextEditingController _rfid;
  final _rfidFocus = FocusNode();
  late VehicleType _type;
  late String _zone;
  bool _busy = false;
  String? _licensePhotoPath;
  String? _orCrPhotoPath;
  String? _licensePhotoUrl;
  String? _orCrPhotoUrl;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _driver = TextEditingController(text: e?.driverName ?? '');
    _plate = TextEditingController(
        text: e?.plateNumber ?? widget.initialPlate ?? '');
    _rfid = TextEditingController(text: e?.rfidTag ?? '');
    _type =
        e == null ? VehicleType.car : VehicleType.fromLabel(e.vehicleType);
    _zone = e?.defaultZoneId ?? kZones.first.id;
    _licensePhotoPath = e?.driverLicensePhotoPath;
    _orCrPhotoPath = e?.orCrPhotoPath;
    _licensePhotoUrl = e?.driverLicensePhotoUrl;
    _orCrPhotoUrl = e?.orCrPhotoUrl;
  }

  /// Opens [VehicleAttachmentScreen] to capture (or retake) the driver's
  /// license and OR/CR, review the OCR'd name/plate, and Confirm — then
  /// applies whatever it hands back. Vehicle type is included in the
  /// result but only applied when the OR/CR scan actually read one (null
  /// otherwise), so opening this and cancelling — or scanning a document
  /// that doesn't mention a type — never resets a selection already made
  /// on this screen.
  Future<void> _openAttachment() async {
    final result = await Navigator.of(context).push<VehicleAttachmentResult>(
      MaterialPageRoute(
        builder: (_) => VehicleAttachmentScreen(
          initialDriverName: _driver.text,
          initialPlateNumber: _plate.text,
          initialLicensePhotoPath: _licensePhotoPath,
          initialOrCrPhotoPath: _orCrPhotoPath,
          initialLicensePhotoUrl: _licensePhotoUrl,
          initialOrCrPhotoUrl: _orCrPhotoUrl,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _driver.text = result.driverName;
      _plate.text = result.plateNumber;
      _licensePhotoPath = result.licensePhotoPath;
      _orCrPhotoPath = result.orCrPhotoPath;
      _licensePhotoUrl = result.licensePhotoUrl;
      _orCrPhotoUrl = result.orCrPhotoUrl;
      if (result.vehicleType != null) _type = result.vehicleType!;
    });
  }

  @override
  void dispose() {
    _driver.dispose();
    _plate.dispose();
    _rfid.dispose();
    _rfidFocus.dispose();
    super.dispose();
  }

  /// Fires when the RFID field receives an Enter/Return keystroke — a
  /// plug-and-play USB RFID reader enumerates as a USB-HID keyboard and
  /// "types" the tag ID followed by Enter into whichever field has focus,
  /// so a focused text field is all the "connection" this needs. Warns
  /// (without blocking) if the scanned card is already enrolled to a
  /// different plate, since VehicleRegistry.touch settles points by plate,
  /// not tag — two vehicles sharing a tag would quietly split one balance.
  Future<void> _onRfidScanned(String raw) async {
    final tag = raw.trim();
    if (tag.isEmpty) return;
    final match = await VehicleRegistry.instance.lookupByRfid(tag);
    if (!mounted) return;
    final samePlate = match != null &&
        RegisteredVehicle.normalize(match.plateNumber) ==
            RegisteredVehicle.normalize(_plate.text);
    if (match != null && !samePlate) {
      Toast.error(
          context,
          t('Tag $tag is already enrolled to ${match.plateNumber}.',
              'Naka-enroll na ang tag na $tag sa ${match.plateNumber}.'));
      return;
    }
    Toast.success(context, t('Card scanned: $tag', 'Na-scan ang card: $tag'));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // Driver name and plate have their own visible, validated fields, but
    // on VehicleAttachmentScreen now — not this form — so this form's own
    // validate() above can't catch them missing. Same gate as before that
    // screen existed.
    if (_driver.text.trim().length < 2) {
      Toast.error(context,
          t('Open Attachment and scan or type a name first.',
              'Buksan ang Attachment at i-scan o i-type muna ang pangalan.'));
      return;
    }
    if (_plate.text.trim().length < 5) {
      Toast.error(
          context,
          t('Open Attachment and scan or type a plate number first.',
              'Buksan ang Attachment at i-scan o i-type muna ang plaka numero.'));
      return;
    }
    setState(() => _busy = true);
    try {
      await VehicleRegistry.instance.register(
        plateNumber: _plate.text,
        driverName: _driver.text,
        vehicleType: _type.label,
        defaultZoneId: _zone,
        driverLicensePhotoPath: _licensePhotoPath,
        orCrPhotoPath: _orCrPhotoPath,
        driverLicensePhotoUrl: _licensePhotoUrl,
        orCrPhotoUrl: _orCrPhotoUrl,
        rfidTag: _rfid.text,
      );
      HapticFeedback.mediumImpact();
      if (mounted) {
        Toast.success(
            context,
            widget.existing == null
                ? t('Vehicle registered', 'Narehistro ang sasakyan')
                : t('Changes saved', 'Na-save ang mga pagbabago'));
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      // Without this, a failed save (permission-denied, offline with no
      // cache, etc.) used to fail completely silently — no toast, no
      // navigation, just the button quietly stopping — leaving no way to
      // tell "saved" apart from "did nothing" from the UI alone.
      if (mounted) {
        Toast.error(context,
            t("Couldn't save: $e", 'Hindi na-save: $e'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showAppConfirmDialog(
      context,
      title: t('Delete registration?', 'Burahin ang rehistrasyon?'),
      message: t(
          'Remove ${widget.existing!.plateNumber} from the registry? Entry history is kept.',
          'Alisin ang ${widget.existing!.plateNumber} sa registry? Mananatili ang '
              'history ng mga entry.'),
      confirmLabel: t('Delete', 'Burahin'),
      confirmIcon: Icons.delete_outline_rounded,
      confirmColor: YosColors.bad,
    );
    if (ok != true) return;
    await VehicleRegistry.instance.delete(widget.existing!.plateNumber);
    if (mounted) {
      Toast.info(context,
          t('${widget.existing!.plateNumber} removed',
              'Naalis ang ${widget.existing!.plateNumber}'));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
            editing
                ? t('Edit Vehicle', 'I-edit ang Sasakyan')
                : t('Register Vehicle', 'Magrehistro ng Sasakyan'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (editing)
            IconButton(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline_rounded)),
        ],
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                PopIn(
                  child: _AttachmentButton(
                    hasLicense: _licensePhotoPath != null,
                    driverName: _driver.text,
                    plateNumber: _plate.text,
                    onTap: _openAttachment,
                  ),
                ),
                const SizedBox(height: 14),
                PopIn(
                  delayMs: 80,
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('Vehicle Type', 'Uri ng Sasakyan'),
                            style: TextStyle(
                                color: YosColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 16)),
                        const SizedBox(height: 12),
                        GridView.count(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: 2,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 2.2,
                          children: [
                            for (var i = 0; i < VehicleType.values.length; i++)
                              _TypeChip(
                                type: VehicleType.values[i],
                                color: pastelAt(i),
                                selected: VehicleType.values[i] == _type,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _type = VehicleType.values[i]);
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                PopIn(
                  delayMs: 160,
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('Default Zone', 'Default na Zone'),
                            style: TextStyle(
                                color: YosColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 16)),
                        const SizedBox(height: 10),
                        ZoneChipGrid(
                          selectedZoneId: _zone,
                          onChanged: (id) => setState(() => _zone = id),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                PopIn(
                  delayMs: 200,
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('RFID Points', 'RFID Points'),
                            style: TextStyle(
                                color: YosColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 16)),
                        const SizedBox(height: 2),
                        Text(
                            t(
                                'Optional — enroll this vehicle to earn points '
                                    'on every parking fee, redeemable later. Tap the '
                                    'scan icon, then tap a card on the USB reader — '
                                    'or type the ID by hand.',
                                'Opsyonal — i-enroll ang sasakyang ito para makakuha '
                                    'ng points sa bawat bayad sa parking, na maaaring '
                                    'i-redeem sa susunod. Pindutin ang scan icon, tapos '
                                    'i-tap ang card sa USB reader — o i-type nang '
                                    'manu-mano ang ID.'),
                            style:
                                TextStyle(color: YosColors.sub, fontSize: 12)),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _rfid,
                          focusNode: _rfidFocus,
                          textCapitalization: TextCapitalization.characters,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: _onRfidScanned,
                          decoration: InputDecoration(
                            labelText: t('RFID tag ID', 'RFID Tag ID'),
                            hintText: t('e.g. printed on the card',
                                'hal. nakalimbag sa card'),
                            prefixIcon: const Icon(Icons.nfc_rounded),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.contactless_rounded),
                              tooltip: t('Scan a card', 'Mag-scan ng card'),
                              onPressed: () {
                                _rfid.clear();
                                _rfidFocus.requestFocus();
                              },
                            ),
                          ),
                        ),
                        if (editing && widget.existing!.rfidTag != null) ...[
                          const SizedBox(height: 10),
                          Text(
                              t(
                                  '${formatPoints(widget.existing!.points)} Points Balances',
                                  '${formatPoints(widget.existing!.points)} balanse ng points'),
                              style: TextStyle(
                                  color: YosColors.accentDeep,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13)),
                          const SizedBox(height: 12),
                          // Portal access for the card already saved on
                          // this vehicle (not whatever is typed above).
                          OutlinedButton.icon(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => DriverPinDialog(
                                rfidTag: widget.existing!.rfidTag!,
                                driverName: widget.existing!.driverName,
                              ),
                            ),
                            icon: const Icon(Icons.pin_rounded),
                            label: Text(t('Driver portal PIN',
                                'PIN para sa driver portal')),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _busy
                    ? Center(
                        child: CircularProgressIndicator(color: YosColors.ink))
                    : BreathingGlowButton(
                        label: editing
                            ? t('Save changes', 'I-save ang mga Pagbabago')
                            : t('Register Vehicle', 'Magrehistro ng Sasakyan'),
                        icon: Icons.check_rounded,
                        onPressed: _save,
                      ),
                if (editing) ...[
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      t(
                          '${widget.existing!.entryCount} total entries · Registered ${DateFormat('MMM d, y').format(widget.existing!.registeredAt)}',
                          '${widget.existing!.entryCount} kabuuang entry · narehistro noong ${DateFormat('MMM d, y').format(widget.existing!.registeredAt)}'),
                      style: TextStyle(color: YosColors.sub, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Entry point into [VehicleAttachmentScreen] — shows what's been captured
/// so far (or a prompt to start) right on RegisterVehicleScreen, so the
/// collector doesn't have to open it just to check status.
class _AttachmentButton extends StatelessWidget {
  const _AttachmentButton({
    required this.hasLicense,
    required this.driverName,
    required this.plateNumber,
    required this.onTap,
  });

  final bool hasLicense;
  final String driverName;
  final String plateNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // OR/CR is optional — only the license, name and plate gate "complete".
    final complete = hasLicense &&
        driverName.trim().isNotEmpty &&
        plateNumber.trim().isNotEmpty;
    return GlassCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: complete ? YosColors.mint : YosColors.surfaceHigh,
                borderRadius: BorderRadius.circular(14)),
            child: Icon(
                complete
                    ? Icons.check_circle_rounded
                    : Icons.attach_file_rounded,
                color: complete ? YosColors.ink : YosColors.sub),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('Attachment', 'Attachment'),
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 16)),
                Text(
                    complete
                        ? '$driverName · $plateNumber'
                        : t("Scan driver's license",
                            "I-scan ang driver's license"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: YosColors.sub,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: YosColors.sub),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.type,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final VehicleType type;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        decoration: BoxDecoration(
          color: selected ? color : YosColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? YosColors.inkLight : YosColors.glassBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(type.icon, size: 22, color: YosColors.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(type.label,
                    style: TextStyle(
                        color: YosColors.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
