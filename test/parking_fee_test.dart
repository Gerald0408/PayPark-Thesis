// Pricing tests for time-in → time-out billing. Run with:
//   flutter test test/parking_fee_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:yos_app/core/constants.dart';
import 'package:yos_app/core/parking_fee.dart';

/// Prices a visit at the default rates: [type]'s base fee covers the first
/// 3 hours, then its hourly rate per hour started.
ParkingFee price(VehicleType type, DateTime timeIn, DateTime timeOut,
        {bool lostTicket = false, double discount = 0}) =>
    computeParkingFee(
      stay: timeOut.difference(timeIn),
      baseFee: type.fee,
      baseHours: kDefaultBaseHours,
      extraRate: type.extraHourFee,
      lostTicketFee: lostTicket ? kDefaultLostTicketFee : 0,
      discount: discount,
    );

DateTime at(int hour, [int minute = 0]) => DateTime(2026, 10, 7, hour, minute);

void main() {
  test('default rates match the local benchmark (low end)', () {
    expect(kDefaultBaseHours, 3);
    expect((VehicleType.motorcycle.fee, VehicleType.motorcycle.extraHourFee),
        (20.0, 10.0));
    expect((VehicleType.car.fee, VehicleType.car.extraHourFee), (40.0, 15.0));
    expect((VehicleType.van.fee, VehicleType.van.extraHourFee), (60.0, 25.0));
  });

  test('tap in 8:00 AM, tap out 9:00 AM: 1 hour, base fee only', () {
    final p = price(VehicleType.car, at(8), at(9));
    expect(p.stay, const Duration(hours: 1));
    expect(p.extraHours, 0);
    expect(p.total, 40);
  });

  test('exactly 3 hours is still the base fee', () {
    expect(price(VehicleType.car, at(8), at(11)).total, 40);
  });

  test('every hour started after 3 hours is a full hour', () {
    expect(price(VehicleType.car, at(8), at(11, 1)).extraHours, 1); // 3h01m
    expect(price(VehicleType.car, at(8), at(11, 1)).total, 55); // 40 + 15
    expect(price(VehicleType.car, at(8), at(12)).total, 55); // 4h00m
    expect(price(VehicleType.car, at(8), at(12, 1)).total, 70); // 4h01m
  });

  test('rates follow the vehicle type', () {
    // 8:00 AM → 1:30 PM = 5h30m → 3 extra hours.
    expect(price(VehicleType.motorcycle, at(8), at(13, 30)).total, 20 + 3 * 10);
    expect(price(VehicleType.car, at(8), at(13, 30)).total, 40 + 3 * 15);
    expect(price(VehicleType.van, at(8), at(13, 30)).total, 60 + 3 * 25);
  });

  test('overnight stay across midnight', () {
    final p = price(VehicleType.car, DateTime(2026, 10, 6, 22),
        DateTime(2026, 10, 7, 6)); // 8 hours
    expect(p.extraHours, 5);
    expect(p.total, 40 + 5 * 15);
  });

  test('lost ticket adds the lost ticket fee', () {
    expect(price(VehicleType.car, at(8), at(9), lostTicket: true).total,
        40 + kDefaultLostTicketFee);
  });

  test('points discount comes off the base fee only, never below zero', () {
    expect(price(VehicleType.car, at(8), at(9), discount: 10).total, 30);
    expect(price(VehicleType.car, at(8), at(12), discount: 100).total, 15);
  });

  test('time out before time in is treated as zero time', () {
    final p = price(VehicleType.car, at(9), at(8));
    expect(p.stay, Duration.zero);
    expect(p.total, 40);
  });
}
