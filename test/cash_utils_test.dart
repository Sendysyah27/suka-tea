import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/cash.dart';

void main() {
  group('roundUpTo500', () {
    test('total pas 500 naik satu langkah', () {
      expect(roundUpTo500(8000), 8500);
      expect(roundUpTo500(10000), 10500);
    });
    test('total tidak pas dibulatkan ke atas', () {
      expect(roundUpTo500(8100), 8500);
      expect(roundUpTo500(8200), 8500);
      expect(roundUpTo500(8501), 9000);
    });
    test('total kecil', () {
      expect(roundUpTo500(3000), 3500);
      expect(roundUpTo500(1), 500);
    });
  });

  group('computeChange', () {
    test('uang pas = 0', () {
      expect(computeChange(8000, 8000), 0);
    });
    test('lebih bayar = kembalian', () {
      expect(computeChange(10000, 8000), 2000);
    });
    test('kurang bayar = negatif', () {
      expect(computeChange(5000, 8000), -3000);
    });
  });

  group('quickCashAmounts', () {
    test('selalu diawali uang pas, lalu pecahan >= total', () {
      expect(quickCashAmounts(8000), [8000, 10000, 20000, 50000, 100000]);
    });
    test('pecahan di bawah total tidak muncul', () {
      expect(quickCashAmounts(25000), [25000, 50000, 100000]);
    });
    test('total = pecahan tidak duplikat', () {
      expect(quickCashAmounts(10000), [10000, 20000, 50000, 100000]);
    });
    test('total di atas 100K hanya uang pas', () {
      expect(quickCashAmounts(150000), [150000]);
    });
  });
}
