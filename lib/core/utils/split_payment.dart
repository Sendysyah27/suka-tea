/// Matematika split payment murni (tanpa Flutter) — bisa di-unit-test.
///
/// Dipakai alur bayar Split (QRIS + Tunai) di Kasir (Batch C2).
///
/// Aturan:
/// - Bagian QRIS: minimal Rp1.000, dan HARUS kurang dari total — kalau
///   QRIS = total itu bukan split, pakai cara bayar QRIS biasa.
/// - Sisa tunai = total - bagian QRIS; kembalian HANYA dari tunai
///   (QRIS tidak memberi kembalian).
library;

/// Bagian QRIS terkecil yang bisa dipakai dalam split (rupiah).
const int minQrisSplitAmount = 1000;

/// Error validasi bagian QRIS untuk satu total, null = valid.
String? splitQrisError({required int qrisAmount, required int total}) {
  if (qrisAmount < minQrisSplitAmount) {
    return 'Bagian QRIS minimal Rp1.000.';
  }
  if (qrisAmount >= total) {
    return 'Bagian QRIS harus kurang dari total — sisanya dibayar tunai.';
  }
  return null;
}

/// Sisa yang dibayar tunai = total - bagian QRIS.
int splitCashRemainder({required int total, required int qrisAmount}) =>
    total - qrisAmount;

/// Kembalian split = tunai diterima - sisa tunai. Negatif = kurang
/// bayar (sheet tunai mencegah konfirmasi bila kurang).
int splitChange({
  required int cashReceived,
  required int total,
  required int qrisAmount,
}) =>
    cashReceived - (total - qrisAmount);

/// Nominal awal bagian QRIS saat halaman split dibuka: preset terbesar
/// di bawah total, kalau tidak ada — total - Rp1.000, kalau itu pun di
/// bawah minimum — Rp1.000. Bila total <= Rp1.000 tidak ada nilai valid
/// (kembalikan total supaya error validasi yang tampil).
int defaultSplitQrisAmount(int total) {
  const presets = [100000, 50000, 20000, 10000, 5000];
  for (final preset in presets) {
    if (preset >= minQrisSplitAmount && preset < total) return preset;
  }
  final rest = total - 1000;
  if (rest >= minQrisSplitAmount) return rest;
  if (minQrisSplitAmount < total) return minQrisSplitAmount;
  return total;
}
