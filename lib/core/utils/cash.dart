/// Matematika kas tunai murni (tanpa Flutter) — bisa di-unit-test.
///
/// Dipakai sheet "Uang diterima" di Kasir: nominal cepat, kembalian,
/// dan pembulatan QRIS ke Rp500.
library;

/// Bulatkan ke atas ke kelipatan Rp500 terdekat (bila sudah pas,
/// naik satu langkah Rp500 — supaya "Bulatkan" selalu berubah).
int roundUpTo500(int amount) {
  final rounded = ((amount + 499) ~/ 500) * 500;
  return rounded == amount ? rounded + 500 : rounded;
}

/// Kembalian = diterima - total. Negatif = kurang bayar.
int computeChange(int received, int total) => received - total;

/// Nominal cepat untuk bayar tunai: selalu diawali "Uang pas" (= total),
/// lalu pecahan 10K/20K/50K/100K yang >= total. Tanpa duplikat, urut naik.
List<int> quickCashAmounts(int total) {
  const pecahan = [10000, 20000, 50000, 100000];
  final out = <int>{total};
  for (final p in pecahan) {
    if (p >= total) out.add(p);
  }
  return out.toList()..sort();
}
