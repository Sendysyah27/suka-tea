import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';

/// Daftar metode yang BOLEH DIPILIH kasir (Batch C5, perintah Sendy
/// 23 Nov 21:29): Transfer + E-Wallet dihapus dari pilihan karena
/// sudah ada QRIS. Enum lengkap TETAP ADA — transaksi lama
/// Transfer / E-Wallet harus tetap tampil + terhitung di riwayat /
/// laporan / keuangan.
void main() {
  test('metode yang bisa dipilih = Tunai, QRIS, QRIS manual, Split', () {
    expect(selectablePaymentMethods, [
      PaymentMethod.tunai,
      PaymentMethod.qris,
      PaymentMethod.qrisManual,
      PaymentMethod.split,
    ]);
  });

  test('Transfer + E-Wallet TIDAK bisa dipilih', () {
    expect(
      selectablePaymentMethods.contains(PaymentMethod.transfer),
      isFalse,
    );
    expect(
      selectablePaymentMethods.contains(PaymentMethod.ewallet),
      isFalse,
    );
  });

  test('enum Transfer + E-Wallet tetap ada (transaksi lama)', () {
    expect(PaymentMethod.values.contains(PaymentMethod.transfer), isTrue);
    expect(PaymentMethod.values.contains(PaymentMethod.ewallet), isTrue);
    expect(PaymentMethod.values.length, 6);
  });

  test('semua metode pilihan punya label + sublabel di kasir', () {
    // Label dipakai picker metode bayar + chip mode pendek.
    for (final m in selectablePaymentMethods) {
      expect(m.label, isNotEmpty);
    }
  });
}
