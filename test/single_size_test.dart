import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/seed_menu.dart';
import 'package:suka_tea/data/seed_recipes.dart';

/// Ukuran cup tunggal 22oz (Batch C8.2 WS7).
///
/// Poster menu resmi (Sendy, 24 Nov 14:10) adalah sumber kebenaran
/// harga: SATU harga per produk — sama dengan harga "Reguler" lama
/// (JANGAN tambah Rp2.000). Tidak ada 16oz, tidak ada pilihan ukuran.
void main() {
  /// Harga poster per id produk (Rp).
  const posterPrices = <String, int>{
    // Milktea 8K.
    'manggo-milktea': 8000,
    'coklat-milktea': 8000,
    'red-velvet-milktea': 8000,
    'taro-milktea': 8000,
    'thai-tea': 8000,
    // Best Seller.
    'es-teh-jumbo': 3000,
    'es-teh-susu': 5000,
    'es-teh-lemon': 5000,
    'es-teh-yakult': 7000,
    'es-teh-apel': 6000,
    // Mixtea 6K.
    'es-teh-coklat': 6000,
    'es-teh-alpukat': 6000,
    'es-teh-caffe-latte': 6000,
    'es-teh-taro': 6000,
    'es-teh-leci': 6000,
    'es-teh-vanilla-latte': 6000,
    'es-teh-durian': 6000,
    'es-teh-strawberry': 6000,
    'es-teh-permen-karet': 6000,
    'es-teh-green-tea': 6000,
  };

  test('20 produk, tiap produk tepat 1 varian 22oz', () {
    final menu = seedMenu();
    expect(menu, hasLength(20));
    expect(posterPrices, hasLength(20));
    for (final p in menu) {
      expect(
        p.variants,
        hasLength(1),
        reason: '${p.id} harus 1 varian (ditemukan ${p.variants.length})',
      );
      final v = p.variants.first;
      expect(v.id, '${p.id}_22oz', reason: 'id varian ${p.id}');
      expect(v.name, '22oz', reason: 'nama varian ${p.id}');
      expect(v.sizeOz, 22, reason: 'ukuran ${p.id}');
    }
  });

  test('harga tiap produk == harga poster (tanpa +Rp2.000)', () {
    final menu = seedMenu();
    for (final p in menu) {
      final poster = posterPrices[p.id];
      expect(poster, isNotNull, reason: '${p.id} tidak ada di harga poster');
      expect(
        p.variants.first.price,
        poster,
        reason: '${p.id}: harga ${p.variants.first.price} != poster $poster',
      );
    }
  });

  test('nama produk tidak berubah ("Manggo" tetap seperti poster)', () {
    final menu = seedMenu();
    final manggo = menu.firstWhere((p) => p.id == 'manggo-milktea');
    expect(manggo.name, 'Manggo Milktea');
    // Tidak ada produk bernama "Mango" (ejaan poster dipertahankan).
    expect(menu.any((p) => p.name.startsWith('Mango ')), isFalse);
  });

  test('tiap resep 22oz pakai Cup 22oz (bukan Cup 16oz)', () {
    final menu = seedMenu();
    final recipes = seedRecipes();
    expect(recipes, hasLength(20));
    for (final p in menu) {
      final lines = recipes['${p.id}_22oz'];
      expect(lines, isNotNull, reason: 'resep ${p.id}_22oz hilang');
      expect(lines, isNotEmpty);
      final cups =
          lines!.where((l) => l.stockName.startsWith('Cup ')).toList();
      expect(cups, hasLength(1), reason: 'cup ${p.id}');
      expect(cups.first.stockName, 'Cup 22oz');
      expect(cups.first.qty, 1);
      expect(
        lines.any((l) => l.stockName == 'Cup 16oz'),
        isFalse,
        reason: '${p.id} masih pakai Cup 16oz',
      );
    }
  });

  test('tidak ada resep Reguler (_r) atau Jumbo (_j) lagi', () {
    final recipes = seedRecipes();
    for (final key in recipes.keys) {
      expect(key.endsWith('_r'), isFalse, reason: 'resep lama $key');
      expect(key.endsWith('_j'), isFalse, reason: 'resep lama $key');
      expect(key.endsWith('_22oz'), isTrue, reason: 'kunci resep $key');
    }
  });
}
