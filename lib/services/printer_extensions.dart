import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_pos_printer_platform_image_3/flutter_pos_printer_platform_image_3.dart';

import 'printer_service.dart';

/// Add-on helpers for PrinterService that are safe to call from the
/// settings screen. Kept in a separate file so the core service stays
/// unchanged.
extension PrinterServiceExtras on PrinterService {
  /// Send a short, friendly test slip so the collector can visually
  /// confirm the printer is paired and working.
  Future<void> printTest() async {
    if (!isConnected) {
      throw StateError('No printer connected');
    }
    final profile = await CapabilityProfile.load();
    final gen = Generator(PaperSize.mm58, profile);
    final bytes = <int>[];
    bytes.addAll(gen.text('PRINTER TEST',
        styles: const PosStyles(
            align: PosAlign.center, bold: true, height: PosTextSize.size2)));
    bytes.addAll(gen.hr());
    bytes.addAll(gen.text('If you can read this,',
        styles: const PosStyles(align: PosAlign.center)));
    bytes.addAll(gen.text('your printer is ready.',
        styles: const PosStyles(align: PosAlign.center)));
    bytes.addAll(gen.hr());
    bytes.addAll(gen.text(DateTime.now().toString().substring(0, 19),
        styles: const PosStyles(align: PosAlign.center)));
    bytes.addAll(gen.feed(2));
    bytes.addAll(gen.cut());
    await PrinterManager.instance
        .send(type: PrinterType.bluetooth, bytes: bytes);
  }
}
