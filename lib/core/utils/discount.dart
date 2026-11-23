/// Matematika diskon manual murni (tanpa Flutter) — bisa di-unit-test.
///
/// Diskon = nominal rupiah (bukan persen), 0..subtotal. Total yang
/// dibayar = subtotal - diskon. Diskon dicatat di riwayat supaya bisa
/// diaudit (bukan dihapus diam-diam dari total).
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
