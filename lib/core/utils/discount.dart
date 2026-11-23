/// Matematika diskon manual murni (tanpa Flutter) — bisa di-unit-test.
///
/// Diskon = nominal rupiah (bukan persen), 0..subtotal. Total yang
/// dibayar = subtotal - diskon. Diskon dicatat di riwayat supaya bisa
/// diaudit (bukan dihapus diam-diam dari total).
///
/// Mode persen (Batch C4 gabungan, 23 Nov 2026): persen dihitung jadi
/// nominal rupiah di sheet, lalu yang disimpan tetap nominal rupiah
/// (SaleHistory.discount) — TIDAK ada perubahan skema DB. Rumus:
/// `amount = subtotal * persen ~/ 100` — PEMBULATAN KE BAWAH
/// (integer division). Contoh: subtotal Rp19.999 x 33% = Rp6.599
/// (bukan 6.600) — kasir tidak pernah memberi diskon lebih besar
/// dari persen yang diminta.
library;

/// Diskon dijepit ke 0..subtotal: negatif jadi 0, lebih dari subtotal
/// jadi subtotal (total bayar tidak pernah negatif).
int clampDiscount(int discount, int subtotal) {
  if (discount < 0) return 0;
  if (discount > subtotal) return subtotal;
  return discount;
}

/// Total yang harus dibayar sesudah diskon.
int payableAfterDiscount(int subtotal, int discount) =>
    subtotal - clampDiscount(discount, subtotal);

/// Persen dijepit ke 0..100.
int clampPercent(int percent) {
  if (percent < 0) return 0;
  if (percent > 100) return 100;
  return percent;
}

/// Nominal rupiah dari persen subtotal — PEMBULATAN KE BAWAH
/// (subtotal * persen ~/ 100). 100% = tepat subtotal (bukan lebih).
int percentToAmount(int subtotal, int percent) =>
    subtotal * clampPercent(percent) ~/ 100;
