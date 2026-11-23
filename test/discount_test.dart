import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/discount.dart';

void main() {
  test('clampDiscount: negatif jadi 0', () {
    expect(clampDiscount(-5000, 10000), 0);
  });

  test('clampDiscount: dalam rentang tidak berubah', () {
    expect(clampDiscount(0, 10000), 0);
    expect(clampDiscount(3000, 10000), 3000);
    expect(clampDiscount(10000, 10000), 10000);
  });

  test('clampDiscount: lebih dari subtotal jadi subtotal', () {
    expect(clampDiscount(15000, 10000), 10000);
  });

  test('payableAfterDiscount: subtotal - diskon', () {
    expect(payableAfterDiscount(10000, 3000), 7000);
    expect(payableAfterDiscount(10000, 0), 10000);
    expect(payableAfterDiscount(8000, 8000), 0);
  });

  test('payableAfterDiscount: tidak pernah negatif', () {
    expect(payableAfterDiscount(10000, 99999), 0);
    expect(payableAfterDiscount(5000, -1000), 5000);
  });
}
