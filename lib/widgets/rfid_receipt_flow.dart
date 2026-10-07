import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import '../services/firestore_service.dart';
import '../services/locale_controller.dart';
import '../services/registry_service.dart';
import 'toast.dart';
import 'vehicle_type_override_dialog.dart';
import 'visit_flow.dart';

/// The whole "card tapped → receipt" flow (check-in, or check-out when
/// the vehicle is still parked), shared by every screen that
/// listens for an RFID reader (Dashboard, RFID Scan): look the tag up,
/// let the collector pick which of the driver's vehicles it is if the card
/// has several, build the transaction and open the receipt sheet.
///
/// Returns the vehicle the receipt was opened for (after the sheet
/// closes), or null if the tag isn't enrolled or the collector backed out
/// of the vehicle picker.
Future<RegisteredVehicle?> openReceiptForRfidTag(
    BuildContext context, String tag) async {
  final match = await VehicleRegistry.instance.lookupByRfid(tag);
  if (!context.mounted) return null;
  if (match == null) {
    HapticFeedback.vibrate();
    Toast.error(
        context,
        t('No vehicle enrolled with tag "$tag".',
            'Walang sasakyang naka-enroll sa tag na "$tag".'));
    return null;
  }
  final variants = await VehicleRegistry.instance.lookupAllByRfid(tag);
  if (!context.mounted) return null;

  // A vehicle on this card still parked? Then this tap most likely is its
  // check-out, so the sheet opens on TIME OUT — the collector can still
  // flip it to TIME IN (see runVisitFlow).
  ParkingTransaction? open;
  RegisteredVehicle? openVehicle;
  for (final v in variants.isEmpty ? [match] : variants) {
    open = await YosRepository.instance.openVisitFor(v.plateNumber);
    if (!context.mounted) return null;
    if (open != null) {
      openVehicle = v;
      break;
    }
  }

  RegisteredVehicle? checkedIn;
  final done = await runVisitFlow(
    context,
    open: open,
    prepareCheckIn: () async {
      final resolved = await pickVehicleForRfidTag(context,
          tag: tag, current: match, variants: variants);
      if (!context.mounted || resolved == null) return null;
      final tx = YosRepository.instance.buildTransaction(
        driverName: resolved.driverName,
        plateNumber: resolved.plateNumber,
        type: VehicleType.fromLabel(resolved.vehicleType),
        zoneId: resolved.defaultZoneId,
        source: EntrySource.rfid,
      );
      HapticFeedback.heavyImpact();
      Toast.success(context,
          '${resolved.plateNumber} · ${resolved.driverName} · TIME IN');
      checkedIn = resolved;
      return (tx, resolved);
    },
  );
  if (!done) return null;
  return checkedIn ?? openVehicle;
}
