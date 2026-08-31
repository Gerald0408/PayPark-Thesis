import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pos_printer_platform_image_3/flutter_pos_printer_platform_image_3.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/theme.dart';
import '../services/printer_extensions.dart';
import '../services/printer_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';
import '../widgets/glow_effects.dart';

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key, this.embedded = false});

  /// True when hosted as a tab inside RootShell — hides the back arrow.
  final bool embedded;

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final Map<String, PrinterDevice> _devices = {};
  StreamSubscription<PrinterDevice>? _sub;
  bool _scanning = false;
  bool _connecting = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _requestPermsAndScan();
  }

  Future<void> _requestPermsAndScan() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    if (!statuses.values.every((s) => s.isGranted || s.isLimited)) {
      if (mounted) {
        Toast.warn(context,
            'Bluetooth permissions are required to find printers');
      }
    }
    _startScan();
  }

  void _startScan() {
    _sub?.cancel();
    setState(() {
      _scanning = true;
      _devices.clear();
    });
    _sub = PrinterService.instance.scan().listen((d) {
      if (!mounted) return;
      setState(() => _devices[d.address ?? d.name] = d);
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  Future<void> _connect(PrinterDevice d) async {
    setState(() => _connecting = true);
    final ok = await PrinterService.instance.connect(d);
    HapticFeedback.mediumImpact();
    if (mounted) {
      setState(() => _connecting = false);
      if (ok) {
        Toast.success(context, 'Connected to ${d.name}');
      } else {
        Toast.error(context, 'Could not connect to ${d.name}');
      }
    }
  }

  Future<void> _disconnect() async {
    await PrinterService.instance.disconnect();
    if (mounted) setState(() {});
  }

  Future<void> _testPrint() async {
    setState(() => _testing = true);
    try {
      // Send a tiny test slip via the printer service.
      await PrinterService.instance.printTest();
      HapticFeedback.heavyImpact();
      if (mounted) {
        Toast.success(context, 'Test slip sent');
      }
    } catch (e) {
      if (mounted) {
        Toast.error(context, 'Test failed: $e');
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final printer = PrinterService.instance;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded ? null : const BackButton(),
        title: const Text('Printer settings',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TouchGlowOverlay(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              PopIn(
                child: GlassCard(
                  color:
                      printer.isConnected ? YosColors.mint : YosColors.pistachio,
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                        child: Icon(
                            printer.isConnected
                                ? Icons.print_rounded
                                : Icons.print_disabled_rounded,
                            color: YosColors.ink,
                            size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                printer.isConnected
                                    ? printer.connectedName ?? 'Printer'
                                    : 'Printer',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15)),
                            Text(
                                printer.isConnected
                                    ? 'Ready to print receipts'
                                    : 'Pair a Bluetooth thermal printer below',
                                style: const TextStyle(
                                    color: YosColors.ink,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (printer.isConnected)
                Row(
                  children: [
                    Expanded(
                      child: _testing
                          ? const Center(
                              child: SizedBox(
                                  height: 40,
                                  child: CircularProgressIndicator(
                                      color: YosColors.ink)))
                          : BreathingGlowButton(
                              label: 'Test print',
                              icon: Icons.receipt_long_rounded,
                              onPressed: _testPrint,
                            ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _disconnect,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 18),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                      ),
                      icon: const Icon(Icons.link_off_rounded,
                          color: YosColors.ink),
                      label: const Text('Disconnect',
                          style: TextStyle(
                              color: YosColors.ink,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Nearby printers',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                  TextButton.icon(
                    onPressed: _scanning ? null : _startScan,
                    icon: Icon(_scanning
                        ? Icons.hourglass_top_rounded
                        : Icons.refresh_rounded),
                    label: Text(_scanning ? 'Scanning' : 'Rescan'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_devices.isEmpty)
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    child: Column(
                      children: [
                        Icon(
                            _scanning
                                ? Icons.bluetooth_searching_rounded
                                : Icons.bluetooth_disabled_rounded,
                            size: 40,
                            color: YosColors.sub),
                        const SizedBox(height: 10),
                        Text(
                          _scanning
                              ? 'Looking for Bluetooth printers'
                              : 'No printers found. Make sure your printer is on and paired in Bluetooth settings, then rescan.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: YosColors.sub,
                              fontWeight: FontWeight.w600,
                              fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ..._devices.values.map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: GlassCard(
                        onTap: _connecting ? null : () => _connect(d),
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                  color: YosColors.seafoam,
                                  borderRadius: BorderRadius.circular(14)),
                              child: const Icon(Icons.print_rounded,
                                  color: YosColors.ink),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(d.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15)),
                                  Text(d.address ?? '',
                                      style: const TextStyle(
                                          color: YosColors.sub,
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                            _connecting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: YosColors.ink),
                                  )
                                : const Icon(Icons.arrow_forward_rounded,
                                    color: YosColors.sub),
                          ],
                        ),
                      ),
                    )),
            ],
          ),
        ),
      ),
    );
  }
}

