import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_pos_printer_platform_image_3/flutter_pos_printer_platform_image_3.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../models/transaction.dart' show formatStay;
import 'points_settings_service.dart' show formatPoints;

/// Loyalty-points line for a receipt, for an RFID-enrolled vehicle only —
/// see ReceiptPreviewDrawer's `_receiptPoints` getter for how it's
/// computed. Null (no points section at all) for a vehicle that isn't
/// enrolled.
typedef ReceiptPoints = ({
  double earned,
  double redeemed,
  double balance,
  double discountPesos,
});

/// Bluetooth Classic (SPP) thermal printer service.
///
/// Target hardware: 58 mm printers â€” PT-210, PT-200, MTP-II and clones.
/// These are NOT BLE devices, so `isBle: false` is used everywhere.
///
/// Receipt bytes are raw ESC/POS, so no esc_pos_utils dependency is required.
class PrinterService {
  static final PrinterService _instance = PrinterService._internal();

  /// Both `PrinterService()` and `PrinterService.instance` return the
  /// same singleton, so either call style works.
  factory PrinterService() => _instance;
  static PrinterService get instance => _instance;

  PrinterService._internal();

  PrinterManager? _m;
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  PrinterManager get _printerManager {
    if (!isSupported)
      throw Exception("Bluetooth printing works only on the Android app.");
    return _m ??= PrinterManager.instance;
  }

  /// Characters per line on a 58 mm roll at Font A.
  static const int lineWidth = 32;

  /// If "Driver" + a space + the driver's name would be longer than this,
  /// the Driver line prints as a label line followed by one or more
  /// wrapped name lines (see [_wrap]) instead of being truncated by
  /// [_pair]'s normal 32-column width. Deliberately NOT done by switching
  /// the printer to a condensed font (ESC/POS "Font B") — that command
  /// isn't reliably supported across cheap 58 mm clones, and on hardware
  /// that doesn't honor it, it can blank the whole line instead of just
  /// being ignored. Wrapping to another line only ever uses the plain
  /// Font A text commands every one of these printers already handles.
  static const int driverLineThreshold = 30;

  /// Whether [driverName] is long enough that the Driver line needs to
  /// wrap onto extra lines (see [driverLineThreshold]) instead of being
  /// truncated by [_pair]'s normal 32-column width.
  bool needsDriverWrap(String driverName) =>
      'Driver'.length + 1 + driverName.length > driverLineThreshold;

  /// Paper-only shortening for a long name, applied minimally: middle
  /// name(s) collapse to their initial one at a time — starting with
  /// whichever is closest to the surname — stopping the moment the name
  /// fits under [driverLineThreshold], rather than abbreviating every
  /// middle name regardless of whether that much shortening was actually
  /// needed. E.g. "Edward John Gueco Domingo" only needed one word
  /// shortened, so it becomes "Edward John G Domingo" — "John" stays in
  /// full since the name already fit once "Gueco" alone was shortened.
  /// The first and last words are never touched. Only applied when
  /// [needsDriverWrap] is true, and only for what actually prints on the
  /// physical receipt — the on-screen preview always shows the name
  /// exactly as entered (see ReceiptPreviewDrawer, which never calls
  /// this). Two words or fewer are returned unchanged since there's no
  /// middle name to shorten.
  String _abbreviateMiddleNames(String name) {
    final words =
        name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length <= 2) return name.trim();
    for (var i = words.length - 2; i >= 1; i--) {
      if (!needsDriverWrap(words.join(' '))) break;
      words[i] = words[i][0].toUpperCase();
    }
    return words.join(' ');
  }

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------

  StreamSubscription<PrinterDevice>? _discoverySub;
  StreamSubscription<BTStatus>? _statusSub;

  final List<PrinterDevice> _devices = [];
  List<PrinterDevice> get devices => List.unmodifiable(_devices);

  PrinterDevice? _selected;
  PrinterDevice? get selected => _selected;

  bool _connected = false;
  bool get isConnected => _connected;

  bool _scanning = false;
  bool get isScanning => _scanning;

  String? get connectedName => _connected ? _selected?.name : null;
  String? get connectedAddress => _connected ? _selected?.address : null;

  /// Reason for the most recent failure, for display in the UI.
  String? lastError;

  /// Advisory message when permissions look incomplete.
  String? permissionWarning;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Emits whenever the device list, scan state or connection state changes.
  Stream<void> get changes => _changes.stream;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ---------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------

  /// Requests Bluetooth runtime permissions correctly across Android versions.
  ///
  /// `Permission.bluetooth` maps to the legacy API-30-and-below permission.
  /// On Android 12+ it ALWAYS reports denied, so requiring every permission
  /// in one `.every()` check guarantees a false failure â€” that is exactly
  /// what hid the paired PT-210 from the device list.
  Future<bool> requestPermissions() async {
    permissionWarning = null;

    // Modern path: Android 12 (API 31) and newer.
    final scanPerm = await Permission.bluetoothScan.request();
    final connectPerm = await Permission.bluetoothConnect.request();

    if (scanPerm.isGranted && connectPerm.isGranted) return true;

    // Legacy path: Android 11 (API 30) and older. Classic discovery there
    // also requires location permission at runtime.
    final legacy = await Permission.bluetooth.request();
    final location = await Permission.locationWhenInUse.request();

    if (legacy.isGranted && location.isGranted) return true;

    // Some OEM ROMs report odd statuses even when access works.
    if (connectPerm.isGranted) return true;

    permissionWarning =
        (scanPerm.isPermanentlyDenied || connectPerm.isPermanentlyDenied)
            ? 'Nearby devices permission is blocked. Open Settings > Apps > '
                'PayPark > Permissions and allow "Nearby devices".'
            : 'Bluetooth permission was not granted. The printer list may be '
                'incomplete.';

    debugPrint('[PrinterService] scan=$scanPerm connect=$connectPerm '
        'legacy=$legacy location=$location');
    return false;
  }

  Future<void> openSettings() => openAppSettings();

  // ---------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------

  /// Scans for Bluetooth Classic printers, emitting each device as found.
  /// The stream closes itself after [timeout].
  ///
  /// Runs even when permissions look incomplete, because the plugin still
  /// returns already-bonded devices.
  Stream<PrinterDevice> scan({
    Duration timeout = const Duration(seconds: 12),
  }) {
    final controller = StreamController<PrinterDevice>();

    Future<void> begin() async {
      await requestPermissions();
      await stopScan();

      _devices.clear();
      _scanning = true;
      lastError = null;
      _notify();

      _discoverySub = _printerManager
          .discovery(type: PrinterType.bluetooth, isBle: false)
          .listen(
        (device) {
          final address = device.address ?? '';
          if (address.isEmpty) return;
          if (_devices.any((d) => d.address == address)) return;

          _devices.add(device);
          _notify();
          debugPrint('[PrinterService] found ${device.name} ($address)');
          if (!controller.isClosed) controller.add(device);
        },
        onError: (Object e) {
          lastError = e.toString();
          debugPrint('[PrinterService] discovery error: $e');
          if (!controller.isClosed) controller.addError(e);
        },
        cancelOnError: false,
      );

      Timer(timeout, () async {
        await stopScan();
        if (!controller.isClosed) await controller.close();
      });
    }

    controller.onListen = begin;
    controller.onCancel = () async => stopScan();

    return controller.stream;
  }

  /// Devices whose name looks like a thermal printer, filtering out
  /// laptops, phones and speakers.
  List<PrinterDevice> get likelyPrinters {
    const hints = [
      'pt-2',
      'pt2',
      'pt_2',
      'mtp',
      'printer',
      'pos',
      'rpp',
      'bt-'
    ];
    return _devices.where((d) {
      final n = d.name.toLowerCase();
      return hints.any(n.contains);
    }).toList();
  }

  Future<void> stopScan() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    if (_scanning) {
      _scanning = false;
      _notify();
    }
  }

  // ---------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------

  /// Connects and holds the connection open. Returns true on success;
  /// read [lastError] when it returns false.
  Future<bool> connect(PrinterDevice device) async {
    final address = device.address ?? '';
    if (address.isEmpty) {
      lastError = 'That device has no Bluetooth address.';
      return false;
    }

    await _statusSub?.cancel();
    _statusSub = _printerManager.stateBluetooth.listen((status) {
      _connected = status == BTStatus.connected;
      _notify();
    });

    try {
      await _printerManager.connect(
        type: PrinterType.bluetooth,
        model: BluetoothPrinterInput(
          name: device.name,
          address: address,
          isBle: false,
          autoConnect: false,
        ),
      );

      // The SPP socket needs a moment to finish its handshake.
      await Future.delayed(const Duration(milliseconds: 1200));

      _selected = device;
      _connected = true;
      lastError = null;
      _notify();
      debugPrint('[PrinterService] connected to ${device.name}');
      return true;
    } catch (e) {
      _connected = false;
      lastError = 'Could not connect to ${device.name}. Check that it is '
          'powered on, has paper, and is paired in Android Bluetooth '
          'settings. ($e)';
      _notify();
      debugPrint('[PrinterService] connect failed: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _printerManager.disconnect(type: PrinterType.bluetooth);
    } catch (_) {
      // Already disconnected.
    }
    await _statusSub?.cancel();
    _statusSub = null;
    _connected = false;
    _notify();
  }

  // ---------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------

  /// Sends raw bytes over the currently held connection.
  Future<void> sendBytes(List<int> bytes) async {
    if (!_connected) {
      throw const PrinterException('No printer connected.');
    }
    await _printerManager.send(type: PrinterType.bluetooth, bytes: bytes);
  }

  /// One-shot print: connects, sends, disconnects. Kept for callers that
  /// already build their own ESC/POS bytes and pass a name and address.
  Future<bool> printReceipt({
    required String name,
    required String address,
    required List<int> bytes,
  }) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      debugPrint('[PrinterService] Cannot print: missing permissions.');
      // Continue anyway when the device is already bonded â€” some ROMs
      // report denied even though the socket works.
    }

    try {
      debugPrint('[PrinterService] Connecting to $name ($address)...');

      await _printerManager.connect(
        type: PrinterType.bluetooth,
        model: BluetoothPrinterInput(
          name: name,
          address: address,
          isBle: false,
          autoConnect: false,
        ),
      );

      // Wait for the SPP socket handshake before writing.
      await Future.delayed(const Duration(milliseconds: 1500));

      await _printerManager.send(type: PrinterType.bluetooth, bytes: bytes);

      await Future.delayed(const Duration(milliseconds: 500));
      await _printerManager.disconnect(type: PrinterType.bluetooth);

      debugPrint('[PrinterService] Print job completed.');
      return true;
    } catch (e, stackTrace) {
      lastError = e.toString();
      debugPrint('[PrinterService] Error during printing: $e');
      debugPrint(stackTrace.toString());
      try {
        await _printerManager.disconnect(type: PrinterType.bluetooth);
      } catch (_) {}
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Receipts
  // ---------------------------------------------------------------------

  /// Alignment and formatting check.
  Future<void> printTest() async {
    final b = <int>[];
    b.addAll(_init());
    b.addAll(_align(1));
    b.addAll(_size(double_: true));
    b.addAll(_bold(true));
    b.addAll(_text('PAYPARK TEST'));
    b.addAll(_size());
    b.addAll(_bold(false));
    b.addAll(_text(_hr()));
    b.addAll(_text('Printer OK'));
    b.addAll(_text(fmtDateTime(DateTime.now())));
    b.addAll(_align(0));
    b.addAll(_text(_hr()));
    // Exactly 32 characters: should fill the roll with no wrap.
    b.addAll(_text('12345678901234567890123456789012'));
    b.addAll(_feed(3));
    b.addAll(_cut());

    await sendBytes(b);
  }

  /// "Paid via" (and a digital payment's reference number) lines for a
  /// receipt — shared by the printed paper and the on-screen preview so
  /// they never disagree. [methodLabel] is PaymentMethod.label's output.
  List<String> receiptPaymentLines(String methodLabel, String? ref) => [
        _pair('Paid Via', methodLabel),
        if (ref != null && ref.isNotEmpty) _pair('Ref no.', ref),
      ];

  /// "Time in" (and, once checked out, "Time out" + stay length) lines for
  /// a receipt — shared by the printed paper and the on-screen preview.
  /// A time out on a later day than the time in carries its date too.
  List<String> receiptTimeLines(DateTime timeIn, {DateTime? timeOut}) {
    String time(DateTime d) {
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      return '${_two(h)}:${_two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
    }

    final sameDay = timeOut != null &&
        timeOut.year == timeIn.year &&
        timeOut.month == timeIn.month &&
        timeOut.day == timeIn.day;
    return [
      _pair('Time In', time(timeIn)),
      if (timeOut != null) ...[
        _pair('Time Out',
            sameDay ? time(timeOut) : '${_two(timeOut.month)}/${_two(timeOut.day)} ${time(timeOut)}'),
        _pair('Total Time', formatStay(timeOut.difference(timeIn))),
      ],
    ];
  }

  /// Label/value line padded to the paper width — for callers building
  /// their own [printReport] lines.
  String pair(String label, String value) => _pair(label, value);

  /// Full-width divider line, for [printReport] callers.
  String get divider => _hr();

  /// Plain-text report on thermal paper — e.g. the daily blotter. [title]
  /// prints bold and centered, every line of [lines] as-is (callers keep
  /// them within [lineWidth]; [pair] helps), then a timestamp.
  Future<void> printReport(String title, List<String> lines) async {
    final b = <int>[];
    b.addAll(_init());
    b.addAll(_align(1));
    b.addAll(_bold(true));
    for (final line in _wrap(title, lineWidth)) {
      b.addAll(_text(line));
    }
    b.addAll(_bold(false));
    b.addAll(_align(0));
    b.addAll(_text(_hr()));
    for (final line in lines) {
      for (final wrapped in _wrap(line, lineWidth)) {
        b.addAll(_text(wrapped));
      }
    }
    b.addAll(_text(_hr()));
    b.addAll(_align(1));
    b.addAll(_text('Printed ${fmtDateTime(DateTime.now())}'));
    b.addAll(_align(0));
    b.addAll(_feed(3));
    b.addAll(_cut());
    await sendBytes(b);
  }

  // ---------------------------------------------------------------------
  // Time-in ticket — what prints on the first tap. No price yet: the fee
  // is worked out and paid at time out (see printParkingTicket for that
  // full receipt).
  // ---------------------------------------------------------------------

  /// The time-in ticket's lines, for the on-screen preview. Same content
  /// and order as [printTimeInTicket] (which adds the logo above and
  /// prints the time in larger text).
  List<String> timeInTicketLines({
    required String ticketNo,
    required String plateNumber,
    required String vehicleType,
    required String driverName,
    required String zoneId,
    required DateTime timeIn,
    required List<String> rateLines,
    required double lostTicketFee,
    List<String> header = const [],
    List<String> extraLines = const [],
    bool reprint = false,
  }) =>
      [
        ...(header.isEmpty ? ['CONCEPCION PAY PARKING'] : header),
        'PARKING TICKET',
        if (reprint) '*** REPRINT ***',
        _hr(),
        _pair('Ticket', ticketNo),
        _pair('Plate', plateNumber),
        _pair('Vehicle', vehicleType),
        _pair('Driver', driverName),
        _pair('Zone', zoneId.toUpperCase()),
        _hr(),
        'TIME IN',
        _timeOfDay(timeIn),
        _dateOnly(timeIn),
        _hr(),
        ...rateLines,
        _hr(),
        'LOST TICKET FEE: PHP ${lostTicketFee.toStringAsFixed(2)}',
        'Present This Ticket When Leaving',
        'Pay At Time Out',
        ...extraLines,
        'KEEP THIS TICKET.',
      ];

  Future<void> printTimeInTicket({
    required String ticketNo,
    required String plateNumber,
    required String vehicleType,
    required String driverName,
    required String zoneId,
    required DateTime timeIn,
    required List<String> rateLines,
    required double lostTicketFee,
    List<String> header = const [],
    List<String> extraLines = const [],
    bool reprint = false,
  }) async {
    final b = <int>[];
    b.addAll(_init());
    try {
      final logo = await _buildLogoRaster();
      if (logo.isNotEmpty) {
        b.addAll(_align(1));
        b.addAll(logo);
        b.addAll(_feed(1));
      }
    } catch (e) {
      debugPrint('[PrinterService] Logo raster skipped: $e');
    }
    b.addAll(_align(1));
    b.addAll(_bold(true));
    for (final line in header.isEmpty ? ['CONCEPCION PAY PARKING'] : header) {
      b.addAll(_text(line));
    }
    b.addAll(_text('PARKING TICKET'));
    if (reprint) b.addAll(_text('*** REPRINT ***'));
    b.addAll(_bold(false));
    b.addAll(_align(0));
    b.addAll(_text(_hr()));
    for (final line in [
      _pair('Ticket', ticketNo),
      _pair('Plate', plateNumber),
      _pair('Vehicle', vehicleType),
    ]) {
      b.addAll(_text(line));
    }
    final driver = needsDriverWrap(driverName)
        ? _abbreviateMiddleNames(driverName)
        : driverName;
    b.addAll(_text(_pair('Driver', driver)));
    b.addAll(_text(_pair('Zone', zoneId.toUpperCase())));
    b.addAll(_text(_hr()));

    // The time in, big — the one thing this ticket is for.
    b.addAll(_align(1));
    b.addAll(_text('TIME IN'));
    b.addAll(_bold(true));
    b.addAll(_size(double_: true));
    b.addAll(_text(_timeOfDay(timeIn)));
    b.addAll(_size());
    b.addAll(_bold(false));
    b.addAll(_text(_dateOnly(timeIn)));
    b.addAll(_align(0));
    b.addAll(_text(_hr()));
    for (final line in rateLines) {
      b.addAll(_text(line));
    }
    b.addAll(_text(_hr()));
    b.addAll(_align(1));
    b.addAll(_bold(true));
    b.addAll(_text('LOST TICKET FEE: PHP ${lostTicketFee.toStringAsFixed(2)}'));
    b.addAll(_bold(false));
    b.addAll(_text('Present This Ticket When Leaving'));
    b.addAll(_text('Pay At Time Out'));
    for (final line in extraLines) {
      b.addAll(_text(line));
    }
    b.addAll(_text('KEEP THIS TICKET.'));
    b.addAll(_align(0));
    b.addAll(_feed(3));
    b.addAll(_cut());
    await sendBytes(b);
  }

  String _timeOfDay(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${_two(h)}:${_two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  String _dateOnly(DateTime d) =>
      '${_two(d.month)}/${_two(d.day)}/${d.year}';

  /// Rate lines for a ticket: what the base fee covers, the clock time it
  /// covers until, and the hourly rate after — so the driver knows the
  /// price before they leave.
  List<String> rateLines({
    required DateTime timeIn,
    required double baseFee,
    required int baseHours,
    required double extraRate,
  }) =>
      [
        _pair('First ${_hoursLabel(baseHours)}',
            'PHP ${baseFee.toStringAsFixed(2)}'),
        _pair('Covered Until',
            _timeOfDay(timeIn.add(Duration(hours: baseHours)))),
        _pair('Each Hour After', 'PHP ${extraRate.toStringAsFixed(2)}'),
      ];

  String _hoursLabel(int hours) => hours == 1 ? '1 Hour' : '$hours Hours';

  /// Prints a parking ticket from a ParkingTransaction's fields.
  ///
  /// The fee prints as "PHP" rather than the peso sign: 58 mm printers use
  /// CP437/CP1252 and render an unrelated glyph for anything outside those
  /// code pages.
  Future<void> printParkingTicket({
    required String trackingId,
    required String driverName,
    required String plateNumber,
    required String vehicleType,
    required String zoneId,
    required double fee,
    required DateTime timestamp,
    List<String> header = const [],
    String footer = '',
    List<String> closingLines = const [],
    ReceiptPoints? points,
    List<String> paymentLines = const [],
    bool reprint = false,
    List<String> timeLines = const [],
    String? banner,
  }) async {
    await sendBytes(await buildParkingTicketBytes(
      paymentLines: paymentLines,
      reprint: reprint,
      timeLines: timeLines,
      banner: banner,
      trackingId: trackingId,
      driverName: driverName,
      plateNumber: plateNumber,
      vehicleType: vehicleType,
      zoneId: zoneId,
      fee: fee,
      timestamp: timestamp,
      header: header,
      footer: footer,
      closingLines: closingLines,
      points: points,
    ));
  }

  /// The exact text lines [buildParkingTicketBytes] will print, in order —
  /// same 32-char monospace width, same [_pair] behavior as
  /// [buildParkingTicketBytes], for every field except Driver: the Driver
  /// row is left out of both lists entirely — the caller (in
  /// ReceiptPreviewDrawer) renders it as its own widget instead, with
  /// "Driver" fixed-size and only the name shrinking to fit (mirroring
  /// [_buildDriverNameRaster]'s approach for the printed paper, where a
  /// long name has no choice but to wrap onto extra lines since there's
  /// no such thing as a smaller font in plain ESC/POS text — only the
  /// rendered-as-an-image raster can keep the label full size there).
  List<String> previewLinesBeforeDriver({
    required String trackingId,
    List<String> header = const [],
  }) =>
      [
        ...(header.isEmpty ? ['CONCEPCION PAY PARKING'] : header),
        _hr(),
        _pair('Receipt', trackingId),
      ];

  List<String> previewLinesAfterDriver({
    required String plateNumber,
    required String vehicleType,
    required String zoneId,
    required double fee,
    required DateTime timestamp,
    String footer = '',
    List<String> closingLines = const [],
    ReceiptPoints? points,
    List<String> paymentLines = const [],
    List<String> timeLines = const [],
  }) =>
      [
        _pair('Plate', plateNumber),
        _pair('Vehicle', vehicleType),
        _pair('Zone', zoneId.toUpperCase()),
        ...timeLines,
        if (points != null) ..._pointsLines(points),
        _hr(),
        'PHP ${fee.toStringAsFixed(2)}',
        '(${_amountInWords(fee)})',
        ...paymentLines,
        _hr(),
        fmtDateTime(timestamp),
        if (footer.isNotEmpty) footer,
        ...closingLines,
        'KEEP THIS RECEIPT.',
      ];

  /// Points lines for an RFID-enrolled vehicle — the Discount/Points
  /// redeemed pair only shown when something was actually redeemed this
  /// visit, earned and the resulting balance always shown. The peso
  /// Discount line sits right above Points redeemed rather than being
  /// left implicit in a lower PHP total — a customer seeing only
  /// "Points redeemed: -0.3" (or the fee line already discounted, with
  /// no line at all) has no way to check the peso value that actually
  /// bought. Shared between the printed paper and the on-screen preview
  /// so they never disagree.
  List<String> _pointsLines(ReceiptPoints points) => [
        if (points.redeemed > 0) ...[
          _pair('Discount', '-PHP ${points.discountPesos.toStringAsFixed(2)}'),
          _pair('Points Redeemed', '-${formatPoints(points.redeemed)}'),
        ],
        _pair('Points Earned', '+${formatPoints(points.earned)}'),
        _pair('Points Balances', formatPoints(points.balance)),
      ];

  /// Builds the ESC/POS bytes for a parking ticket without sending them.
  /// Useful with the one-shot [printReceipt] above.
  Future<List<int>> buildParkingTicketBytes({
    required String trackingId,
    required String driverName,
    required String plateNumber,
    required String vehicleType,
    required String zoneId,
    required double fee,
    required DateTime timestamp,
    List<String> header = const [],
    String footer = '',
    List<String> closingLines = const [],
    ReceiptPoints? points,
    List<String> paymentLines = const [],
    bool reprint = false,
    List<String> timeLines = const [],
    String? banner,
  }) async {
    final b = <int>[];
    b.addAll(_init());

    // Logo, centered above the header text. Failure here (missing
    // asset, decode error) must never block the receipt itself, so it's
    // swallowed — worst case the receipt just prints without a logo.
    try {
      final logo = await _buildLogoRaster();
      if (logo.isNotEmpty) {
        b.addAll(_align(1));
        b.addAll(logo);
        b.addAll(_feed(1));
      }
    } catch (e) {
      debugPrint('[PrinterService] Logo raster skipped: $e');
    }

    // Header
    b.addAll(_align(1));
    b.addAll(_bold(true));
    if (header.isEmpty) {
      b.addAll(_text('CONCEPCION PAY PARKING'));
    } else {
      for (final line in header) {
        b.addAll(_text(line));
      }
    }
    // A copy printed later from Transaction Logs — marked so it can't be
    // passed off as a second, separate payment.
    if (reprint) b.addAll(_text('*** REPRINT ***'));
    if (banner != null) b.addAll(_text(banner));
    b.addAll(_bold(false));
    b.addAll(_align(0));
    b.addAll(_text(_hr()));

    // Body — when the driver's name is too long for one line at the
    // printer's own font, the middle name(s) abbreviate to an initial
    // first (paper only — see _abbreviateMiddleNames; the on-screen
    // preview always shows the name exactly as entered). If that alone
    // gets it back under the normal width, it prints as plain text like
    // any other name. Only if it's still too long even abbreviated does
    // it fall back to the rendered-as-an-image raster (_buildDriverNameRaster),
    // scaled to fit, so it stays on one line beside "Driver" rather than
    // truncating or dropping to a second line. Every other field still
    // fits the normal 32-column width as plain text.
    b.addAll(_text(_pair('Receipt', trackingId)));
    if (needsDriverWrap(driverName)) {
      final abbreviated = _abbreviateMiddleNames(driverName);
      if (!needsDriverWrap(abbreviated)) {
        b.addAll(_text(_pair('Driver', abbreviated)));
      } else {
        final raster = await _buildDriverNameRaster(abbreviated);
        if (raster.isNotEmpty) {
          b.addAll(_align(0));
          b.addAll(raster);
          b.addAll(_feed(1));
        } else {
          // Rendering failed for some reason — fall back to a wrapped
          // plain-text line rather than losing the name entirely.
          b.addAll(_text('Driver'));
          for (final line in _wrap(abbreviated, lineWidth)) {
            b.addAll(_text(line));
          }
        }
      }
    } else {
      b.addAll(_text(_pair('Driver', driverName)));
    }
    b.addAll(_text(_pair('Plate', plateNumber)));
    b.addAll(_text(_pair('Vehicle', vehicleType)));
    b.addAll(_text(_pair('Zone', zoneId.toUpperCase())));
    for (final line in timeLines) {
      b.addAll(_text(line));
    }
    if (points != null) {
      for (final line in _pointsLines(points)) {
        b.addAll(_text(line));
      }
    }
    b.addAll(_text(_hr()));

    // Fee
    b.addAll(_bold(true));
    b.addAll(_size(double_: true));
    b.addAll(_align(1));
    b.addAll(_text('PHP ${fee.toStringAsFixed(2)}'));
    b.addAll(_size());
    b.addAll(_bold(false));
    b.addAll(_text('(${_amountInWords(fee)})'));
    b.addAll(_align(0));
    for (final line in paymentLines) {
      b.addAll(_text(line));
    }
    b.addAll(_text(_hr()));

    // Footer
    b.addAll(_align(1));
    b.addAll(_text(fmtDateTime(timestamp)));
    if (footer.isNotEmpty) b.addAll(_text(footer));
    for (final line in closingLines) {
      b.addAll(_text(line));
    }
    b.addAll(_text('KEEP THIS RECEIPT.'));
    b.addAll(_align(0));
    b.addAll(_feed(3));
    b.addAll(_cut());

    return b;
  }

  /// Cached ESC/POS raster-image command for the barangay seal, so the
  /// PNG only gets decoded and dithered once per app session rather than
  /// on every single print.
  List<int>? _logoRasterCache;

  /// Converts assets/icon/logo_receipt.png into a GS v 0 raster-image
  /// command —
  /// the ESC/POS command for printing a monochrome bitmap. Thermal
  /// printers have no concept of image files; they only understand a
  /// packed 1-bit-per-pixel bitmap sent as raw bytes.
  Future<List<int>> _buildLogoRaster() async {
    final cached = _logoRasterCache;
    if (cached != null) return cached;

    final data = await rootBundle.load('assets/icon/logo_receipt.png');
    final decoded = img.decodeImage(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    if (decoded == null) return const [];

    // 58 mm printers are commonly 384 dots wide (8 dots/mm), but printing
    // the logo at full width eats too much paper on every single receipt.
    // 200 dots (~25 mm) keeps it a compact header without dominating the
    // ticket. "Average" interpolation is avoided here since it would blur
    // the bundled art's pre-dithered hard black/white pixels to gray; those
    // pixels then get re-thresholded below and thin lines vanish instead of
    // surviving as either black or white. Nearest-neighbor keeps edges
    // crisp instead of blurring.
    const maxWidth = 200;
    final resized = decoded.width <= maxWidth
        ? decoded
        : img.copyResize(decoded,
            width: maxWidth, interpolation: img.Interpolation.nearest);

    // Some logos have a transparent background, so alpha has to be checked
    // too — otherwise fully transparent pixels (often RGB 0,0,0 under the
    // hood) read as "black" by luminance alone and print as a solid black
    // square instead of a blank background. But formats with no alpha
    // channel at all (opaque JPEGs, 1-bit grayscale PNGs) report `.a` as 0
    // rather than "fully opaque", so gating on it unconditionally would
    // blank the whole image — the gate only applies when alpha exists.
    final hasAlpha = resized.hasAlpha;
    // Single-channel (grayscale) sources store their intensity directly in
    // the red channel with green/blue left at 0. Pixel.luminance applies
    // RGB weighting (0.299r + 0.587g + 0.114b) regardless, which caps a
    // pure-grayscale pixel at 29.9% of its true value — always below the
    // 50% threshold, so every pixel would misread as black. Reading the
    // red channel directly avoids that.
    final isGrayscaleSource = resized.numChannels == 1;
    final threshold = resized.maxChannelValue / 2;
    final widthBytes = (resized.width + 7) ~/ 8;
    final raster = Uint8List(widthBytes * resized.height);
    for (var y = 0; y < resized.height; y++) {
      for (var x = 0; x < resized.width; x++) {
        final pixel = resized.getPixel(x, y);
        final isOpaque = !hasAlpha || pixel.a > threshold;
        final intensity = isGrayscaleSource ? pixel.r : pixel.luminance;
        if (isOpaque && intensity < threshold) {
          raster[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7);
        }
      }
    }

    final bytes = <int>[
      29, 118, 48, 0, // GS v 0, mode 0 (normal, no scaling)
      widthBytes & 0xFF, (widthBytes >> 8) & 0xFF,
      resized.height & 0xFF, (resized.height >> 8) & 0xFF,
      ...raster,
    ];
    _logoRasterCache = bytes;
    return bytes;
  }

  /// Renders "Driver  &lt;name&gt;" as a small bitmap and returns it as an
  /// ESC/POS raster-image command (same GS v 0 command as
  /// [_buildLogoRaster]) — used only when the driver's name is too long
  /// to print as plain text on one line (see [needsDriverWrap]). "Driver"
  /// itself always renders at [labelFontSize]; only the name shrinks, by
  /// however much is needed to fit what's left of the printer's usable
  /// width after the label.
  ///
  /// Deliberately NOT done by switching the printer's built-in font (ESC
  /// M / "Font B"): that command isn't reliably supported across cheap
  /// 58 mm clones, and on hardware that doesn't honor it, it can blank
  /// the whole line instead of being safely ignored (confirmed on an
  /// actual unit). Rendering the text ourselves and sending it as pixels
  /// works on any printer that can print an image at all — which this
  /// one already does, for the header logo.
  Future<List<int>> _buildDriverNameRaster(String driverName) async {
    // 58 mm heads are commonly 384 dots wide (8 dots/mm); a few dots of
    // margin avoids edge clipping on units that crop right at the limit.
    const targetWidth = 376.0;
    const labelFontSize = 28.0;

    TextPainter layoutText(String text, double fontSize) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
              fontFamily: 'monospace',
              fontSize: fontSize,
              color: const Color(0xFF000000)),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      return tp;
    }

    final label = layoutText('Driver  ', labelFontSize);
    final availableForName = targetWidth - label.width;

    // One direct scale-to-fit pass for the name only: text width is
    // effectively linear in font size for a fixed string/font, so
    // measuring once at the label's size and scaling proportionally lands
    // within a fraction of a dot of the target — no need to iterate.
    var nameFontSize = labelFontSize;
    var name = layoutText(driverName, nameFontSize);
    if (availableForName > 0 && name.width > availableForName) {
      nameFontSize *= availableForName / name.width;
      name = layoutText(driverName, nameFontSize);
    }

    final width = (label.width + name.width).ceil();
    final height =
        [label.height, name.height].reduce((a, b) => a > b ? a : b).ceil();
    if (width <= 0 || height <= 0) return const [];

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xFFFFFFFF));
    // Vertically centered within the shared line height, so the smaller
    // name sits comfortably alongside the full-size label.
    label.paint(canvas, Offset(0, (height - label.height) / 2));
    name.paint(canvas, Offset(label.width, (height - name.height) / 2));
    final uiImage = await recorder.endRecording().toImage(width, height);
    final byteData =
        await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return const [];
    final rgba = byteData.buffer.asUint8List();

    final widthBytes = (width + 7) ~/ 8;
    final raster = Uint8List(widthBytes * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final luminance =
            0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
        if (luminance < 128) {
          raster[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7);
        }
      }
    }

    return <int>[
      29, 118, 48, 0, // GS v 0, mode 0 (normal, no scaling)
      widthBytes & 0xFF, (widthBytes >> 8) & 0xFF,
      height & 0xFF, (height >> 8) & 0xFF,
      ...raster,
    ];
  }

  // ---------------------------------------------------------------------
  // Raw ESC/POS helpers
  // ---------------------------------------------------------------------

  List<int> _init() => [27, 64]; // ESC @

  List<int> _align(int n) =>
      [27, 97, n]; // ESC a n  (0 left, 1 center, 2 right)

  List<int> _bold(bool on) => [27, 69, on ? 1 : 0]; // ESC E n

  // GS ! n â€” 0x00 normal, 0x11 double width and height
  List<int> _size({bool double_ = false}) => [29, 33, double_ ? 0x11 : 0x00];

  List<int> _feed(int lines) => List<int>.filled(lines, 10);

  List<int> _cut() =>
      [29, 86, 1]; // GS V 1 (ignored by printers with no cutter)

  /// Encodes a line of text plus a newline. Characters outside Latin-1 are
  /// replaced, since these printers cannot render them.
  List<int> _text(String s) {
    final out = <int>[];
    for (final unit in s.runes) {
      out.add(unit < 256 ? unit : 63); // 63 == '?'
    }
    out.add(10);
    return out;
  }

  String _hr() => '-' * lineWidth;

  /// Label on the left, value right-aligned, padded to the full line width.
  String _pair(String label, String value) {
    final space = lineWidth - label.length - value.length;
    if (space >= 1) return label + ' ' * space + value;

    // Too long to fit: truncate the value rather than wrapping.
    final room = lineWidth - label.length - 1;
    if (room <= 0) return label.substring(0, lineWidth);
    return '$label ${value.substring(0, room)}';
  }

  /// Splits [text] into chunks of at most [width] characters, breaking on
  /// spaces where possible so a word isn't cut mid-word — used only for
  /// the Driver line when the name is too long for one line (see
  /// [needsDriverWrap]), so the full name still prints across as many
  /// lines as it needs instead of being cut off or relying on a printer
  /// font command that isn't reliably supported.
  List<String> _wrap(String text, int width) {
    final words = text.trim().split(RegExp(r'\s+'));
    final lines = <String>[];
    var current = '';
    for (final word in words) {
      final candidate = current.isEmpty ? word : '$current $word';
      if (candidate.length <= width) {
        current = candidate;
        continue;
      }
      if (current.isNotEmpty) lines.add(current);
      // A single word longer than the width still has to hard-break.
      var rest = word;
      while (rest.length > width) {
        lines.add(rest.substring(0, width));
        rest = rest.substring(width);
      }
      current = rest;
    }
    if (current.isNotEmpty) lines.add(current);
    return lines;
  }

  static const List<String> _ones = [
    '',
    'One',
    'Two',
    'Three',
    'Four',
    'Five',
    'Six',
    'Seven',
    'Eight',
    'Nine',
    'Ten',
    'Eleven',
    'Twelve',
    'Thirteen',
    'Fourteen',
    'Fifteen',
    'Sixteen',
    'Seventeen',
    'Eighteen',
    'Nineteen',
  ];

  static const List<String> _tens = [
    '',
    '',
    'Twenty',
    'Thirty',
    'Forty',
    'Fifty',
    'Sixty',
    'Seventy',
    'Eighty',
    'Ninety',
  ];

  /// Spells out a whole-peso amount, e.g. 150.0 -> "One Hundred Fifty Pesos".
  /// Fractional centavos are rounded away since ordinance fees are whole pesos.
  String _amountInWords(double fee) {
    final pesos = fee.round();
    if (pesos == 0) return 'Zero Pesos';
    return '${_spellInteger(pesos)} ${pesos == 1 ? 'Peso' : 'Pesos'}';
  }

  String _spellInteger(int n) {
    if (n < 20) return _ones[n];
    if (n < 100) {
      final tens = _tens[n ~/ 10];
      final ones = n % 10;
      return ones == 0 ? tens : '$tens-${_ones[ones]}';
    }
    if (n < 1000) {
      final head = '${_ones[n ~/ 100]} Hundred';
      final rest = n % 100;
      return rest == 0 ? head : '$head ${_spellInteger(rest)}';
    }
    final head = '${_spellInteger(n ~/ 1000)} Thousand';
    final rest = n % 1000;
    return rest == 0 ? head : '$head ${_spellInteger(rest)}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String fmtDateTime(DateTime d) {
    final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final period = d.hour < 12 ? 'AM' : 'PM';
    return '${_two(d.month)}/${_two(d.day)}/${d.year} '
        '${_two(hour12)}:${_two(d.minute)} $period';
  }

  void dispose() {
    _discoverySub?.cancel();
    _statusSub?.cancel();
    _changes.close();
  }
}

class PrinterException implements Exception {
  final String message;
  const PrinterException(this.message);

  @override
  String toString() => message;
}
