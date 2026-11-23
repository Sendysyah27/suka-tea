import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/split_payment.dart';

/// Matematika split payment (Batch C2) — level fungsi saja.
/// Aturan: bagian QRIS min Rp1.000 dan harus kurang dari total;
/// sisa tunai = total - bagian QRIS; kembalian hanya dari tunai.
void main() {
  group('splitQrisError', () {
    test('bagian QRIS di bawah Rp1.000 ditolak', () {
      expect(splitQrisError(qrisAmount: 999, total: 21000), isNotNull);
      expect(splitQrisError(qrisAmount: 0, total: 21000), isNotNull);
    });

    test('bagian QRIS Rp1.000 (batas bawah) diterima', () {
      expect(splitQrisError(qrisAmount: 1000, total: 21000), isNull);
    });

    test('bagian QRIS = total ditolak (itu bukan split)', () {
      expect(
        splitQrisError(qrisAmount: 21000, total: 21000),
        isNotNull,
      );
    });

    test('bagian QRIS > total ditolak', () {
      expect(splitQrisError(qrisAmount: 25000, total: 21000), isNotNull);
    });

    test('bagian QRIS = total - 1 (batas atas) diterima', () {
      expect(splitQrisError(qrisAmount: 20999, total: 21000), isNull);
    });

    test('total Rp1.000 tidak bisa di-split (tidak ada nilai valid)', () {
      expect(splitQrisError(qrisAmount: 1000, total: 1000), isNotNull);
      expect(splitQrisError(qrisAmount: 999, total: 1000), isNotNull);
    });
  });

  group('splitCashRemainder', () {
    test('total 21000, QRIS 10000 -> sisa tunai 11000', () {
      expect(
        splitCashRemainder(total: 21000, qrisAmount: 10000),
        11000,
      );
    });

    test('total 8000, QRIS 5000 -> sisa tunai 3000', () {
      expect(splitCashRemainder(total: 8000, qrisAmount: 5000), 3000);
    });
  });

  group('defaultSplitQrisAmount', () {
    test('total 21000 -> preset terbesar di bawah total (20000)', () {
      expect(defaultSplitQrisAmount(21000), 20000);
    });

    test('total 8000 -> preset 5000', () {
      expect(defaultSplitQrisAmount(8000), 5000);
    });

    test('total 3000 -> total - 1000 = 2000', () {
      expect(defaultSplitQrisAmount(3000), 2000);
    });

    test('total 1500 -> minimum 1000', () {
      expect(defaultSplitQrisAmount(1500), 1000);
    });

    test('total 1000 -> tidak ada nilai valid, kembalikan total', () {
      expect(defaultSplitQrisAmount(1000), 1000);
      expect(
        splitQrisError(
          qrisAmount: defaultSplitQrisAmount(1000),
          total: 1000,
        ),
        isNotNull,
      );
    });

    test('nilai awal selalu valid bila ada nilai valid', () {
      for (final total in [3000, 5000, 8000, 13000, 21000, 100000]) {
        expect(
          splitQrisError(
            qrisAmount: defaultSplitQrisAmount(total),
            total: total,
          ),
          isNull,
        );
      }
    });
  });

  group('splitChange', () {
    test('kembalian hanya dari tunai: diterima 15000, sisa 11000 -> 4000',
        () {
      expect(
        splitChange(cashReceived: 15000, total: 21000, qrisAmount: 10000),
        4000,
      );
    });

    test('tunai pas sisa -> kembalian 0', () {
      expect(
        splitChange(cashReceived: 11000, total: 21000, qrisAmount: 10000),
        0,
      );
    });

    test('tunai kurang dari sisa -> kembalian negatif (kurang bayar)', () {
      expect(
        splitChange(cashReceived: 5000, total: 21000, qrisAmount: 10000),
        -6000,
      );
    });

    test('tunai lebih tidak mengubah bagian QRIS (QRIS tidak berkembalian)',
        () {
      // Total 21000, QRIS 10000, tunai 20000 -> kembalian 9000
      // (20000 - 11000), bukan 20000 - 21000.
      expect(
        splitChange(cashReceived: 20000, total: 21000, qrisAmount: 10000),
        9000,
      );
    });
  });
}
