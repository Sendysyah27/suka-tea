import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/money.dart';

void main() {
  test('formatRupiah', () {
    expect(formatRupiah(3000), 'Rp3.000');
    expect(formatRupiah(12500), 'Rp12.500');
    expect(formatRupiah(1000000), 'Rp1.000.000');
    expect(formatRupiah(0), 'Rp0');
  });
}
