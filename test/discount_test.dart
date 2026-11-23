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

  test('clampPercent: dijepit 0..100', () {
    expect(clampPercent(-5), 0);
    expect(clampPercent(0), 0);
    expect(clampPercent(10), 10);
    expect(clampPercent(100), 100);
    expect(clampPercent(150), 100);
  });

  test('percentToAmount: subtotal * persen ~/ 100 (bulat ke bawah)', () {
    expect(percentToAmount(21000, 10), 2100);
    expect(percentToAmount(21000, 100), 21000);
    expect(percentToAmount(21000, 0), 0);
    // 19.999 x 33% = 6.599,67 -> 6.599 (BUKAN 6.600).
    expect(percentToAmount(19999, 33), 6599);
    // Persen di luar 0..100 dijepit dulu, bukan dibiarkan lewat.
    expect(percentToAmount(10000, 150), 10000);
    expect(percentToAmount(10000, -10), 0);
  });
}
