import '../../data/models.dart';

/// Helper murni untuk keranjang Kasir (Batch C5) — tanpa BuildContext,
/// supaya bisa di-test langsung.
///
/// Dipakai untuk: badge angka di kartu produk (qty per produk) dan
/// edit baris keranjang (ganti varian + modifier, qty dipertahankan).

/// Total qty per produk di [cart], semua varian (Reguler + Jumbo)
/// digabung. Key = product.id, value = total qty. Keranjang kosong
/// menghasilkan map kosong.
Map<String, int> cartQtyByProduct(List<CartItem> cart) {
  final map = <String, int>{};
  for (final item in cart) {
    map[item.product.id] = (map[item.product.id] ?? 0) + item.qty;
  }
  return map;
}

/// true bila dua daftar modifier isinya SAMA (tiap nama + harga
/// delta cocok, urutan tidak penting). Dipakai untuk menentukan
/// apakah dua baris keranjang itu duplikat.
bool sameModifiers(List<Modifier> a, List<Modifier> b) {
  if (a.length != b.length) return false;
  final bKeys = b
      .map((m) => '${m.kind}|${m.name}|${m.priceDelta}')
      .toSet();
  return a
      .map((m) => '${m.kind}|${m.name}|${m.priceDelta}')
      .every(bKeys.contains);
}

/// Ganti baris keranjang [index] dengan [variant] + [modifiers] baru
/// (hasil edit lewat sheet opsi). Qty baris itu dipertahankan.
///
/// Bila hasil edit SAMA PERSIS dengan baris lain (produk + varian +
/// modifier identik), qty digabung ke baris itu dan baris [index]
/// dihapus — keranjang tidak pernah punya dua baris identik.
/// Mengembalikan list BARU; [cart] tidak diubah.
/// Index di luar rentang menghasilkan salinan [cart] tanpa perubahan.
List<CartItem> replaceCartItem(
  List<CartItem> cart,
  int index,
  ProductVariant variant,
  List<Modifier> modifiers,
) {
  if (index < 0 || index >= cart.length) return List.of(cart);
  final target = cart[index];
  // Cari baris lain yang akan jadi duplikat sesudah edit.
  int? duplicateIndex;
  for (var i = 0; i < cart.length; i++) {
    if (i == index) continue;
    final other = cart[i];
    if (other.product.id == target.product.id &&
        other.variant.id == variant.id &&
        sameModifiers(other.modifiers, modifiers)) {
      duplicateIndex = i;
      break;
    }
  }
  if (duplicateIndex == null) {
    final updated = List.of(cart);
    updated[index] = CartItem(
      product: target.product,
      variant: variant,
      modifiers: List.of(modifiers),
      qty: target.qty,
    );
    return updated;
  }
  // Gabung: qty target ditambah ke baris duplikat, baris target hilang.
  final merged = <CartItem>[];
  for (var i = 0; i < cart.length; i++) {
    if (i == index) continue;
    final other = cart[i];
    if (i == duplicateIndex) {
      merged.add(CartItem(
        product: other.product,
        variant: other.variant,
        modifiers: List.of(other.modifiers),
        qty: other.qty + target.qty,
      ));
    } else {
      merged.add(other);
    }
  }
  return merged;
}
