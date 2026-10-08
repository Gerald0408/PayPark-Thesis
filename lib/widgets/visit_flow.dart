import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/registered_vehicle.dart';
import '../models/transaction.dart';
import 'check_out_sheet.dart';
import 'time_in_ticket_sheet.dart';

/// What a receipt sheet pops with when the collector picks the other mode
/// ("check it out instead" / "new TIME IN instead") — the caller
/// ([runVisitFlow]) then opens the other sheet.
const String kSwitchVisitMode = 'switch_visit_mode';

/// Opens the right sheet for a vehicle: TIME OUT (pay and get the full
/// receipt) when [open] is its still-parked visit, else TIME IN (print the
/// time-in ticket, nothing paid yet) — and lets the collector switch
/// between the two. [prepareCheckIn] builds the time-in transaction the
/// first time TIME IN is shown (it may ask the collector things, e.g.
/// which of a card's vehicles; returning null cancels). [redeemTier]
/// pre-selects a points discount at time out (RFID Points' redeem button).
/// Resolves true once a time-in was saved or a time-out paid.
Future<bool> runVisitFlow(
  BuildContext context, {
  required ParkingTransaction? open,
  required Future<(ParkingTransaction, RegisteredVehicle?)?> Function()
      prepareCheckIn,
  int? redeemTier,
}) async {
  var timeOut = open != null;
  (ParkingTransaction, RegisteredVehicle?)? checkIn;
  while (context.mounted) {
    if (timeOut) {
      final result = await showCheckOutSheet(context, open!,
          canSwitchToTimeIn: true, redeemTier: redeemTier);
      if (result == CheckOutOutcome.switchMode) {
        timeOut = false;
        continue;
      }
      return result == CheckOutOutcome.done;
    }
    checkIn ??= await prepareCheckIn();
    if (checkIn == null || !context.mounted) return false;
    final (tx, registered) = checkIn;
    final result = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => TimeInTicketSheet(
        tx: tx,
        registered: registered,
        canSwitchToTimeOut: open != null,
        onDone: () => Navigator.of(sheetContext).pop(true),
      ),
    );
    if (result == kSwitchVisitMode) {
      timeOut = true;
      continue;
    }
    return result == true;
  }
  return false;
}

/// Big TIME IN / TIME OUT tile showing the time (or [placeholder] when
/// none is set yet). The visit sheets pass a null [onTap]: both times are
/// set automatically by the card taps and can't be edited.
class TimeChoiceButton extends StatelessWidget {
  const TimeChoiceButton({
    super.key,
    required this.label,
    required this.icon,
    required this.time,
    required this.onTap,
    this.placeholder,
    this.highlight = false,
  });

  final String label;
  final IconData icon;
  final DateTime? time;
  final VoidCallback? onTap;
  final String? placeholder;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final set = time != null;
    final fg = highlight ? YosColors.onAccent : YosColors.ink;
    return Material(
      color: highlight ? YosColors.accent : YosColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 84),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: highlight ? YosColors.accentDeep : YosColors.glassBorder,
                width: highlight ? 2 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: fg),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          color: fg, fontSize: 16, fontWeight: FontWeight.w900)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                        set
                            ? TimeOfDay.fromDateTime(time!).format(context)
                            : (placeholder ?? '--:--'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: set ? fg : YosColors.sub,
                            fontSize: set ? 22 : 15,
                            fontWeight: set ? FontWeight.w900 : FontWeight.w600)),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.edit_rounded,
                        size: 16, color: highlight ? fg : YosColors.sub),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

