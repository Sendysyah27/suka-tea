import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/recipe_logic.dart';
import 'package:suka_tea/data/seed_menu.dart';
import 'package:suka_tea/data/seed_recipes.dart';

/// Unit test fungsi murni resep (tanpa Flutter/Drift).
/// Angka acuan = seedRecipes() untuk Manggo Milktea (Batch C8.2 WS7:
/// SATU resep 22oz — takaran Jumbo lama). Batch C10 WS4: 'Teh'
/// 0.015 kg/cup DIGANTI 'Teh Masak' 0.4 L/cup (teh yang sudah
/// dimasak — hangus harian); takaran lain tetap: Gula 0.035,
///   Susu bubuk 0.030, Bubuk perasa 0.020, Cup 22oz 1, Es batu 0.20,
///   Sedotan 1.
void main() {
  late Map<String, StockItem> stockByName;
  late Map<String, List<RecipeLine>> recipes;
  late Product manggo;

  setUp(() {
    stockByName = {for (final s in seedStock()) s.name: s};
    recipes = seedRecipes();
    manggo = seedMenu().firstWhere((p) => p.id == 'manggo-milktea');
  });

  List<CartItem> cartOf(List<(ProductVariant, int)> lines) => [
        for (final (variant, qty) in lines)
          CartItem(product: manggo, variant: variant, qty: qty),
      ];

  test('deduction 3x Manggo 22oz', () {
    // Satu varian (22oz) — dua baris keranjang digabung jadi 3 cup.
    final cart = cartOf([
      (manggo.variants.first, 2),
      (manggo.variants.last, 1),
    ]);
    final d = computeDeductions(cart, recipes, stockByName);
    expect(d['Teh Masak'], closeTo(1.2, 1e-9));
    expect(d['Gula'], closeTo(0.105, 1e-9));
    expect(d['Susu bubuk'], closeTo(0.090, 1e-9));
    expect(d['Bubuk perasa'], closeTo(0.060, 1e-9));
    expect(d['Cup 22oz'], 3);
    expect(d.containsKey('Cup 16oz'), isFalse);
    expect(d['Es batu'], closeTo(0.60, 1e-9));
    expect(d['Sedotan'], 3);
  });

  test('shortage terdeteksi saat stok kurang', () {
    // Teh Masak seed 0 L -> isi 0.5 L (butuh 1.2 L untuk 3 cup).
    stockByName['Teh Masak'] = const StockItem(
      name: 'Teh Masak',
      unit: 'liter',
      qty: 0.5,
      lowThreshold: 0,
    );
    final cart = cartOf([
      (manggo.variants.first, 2),
      (manggo.variants.last, 1),
    ]);
    final shortages = findShortages(cart, recipes, stockByName);
    expect(shortages, hasLength(1));
    expect(shortages.first.stockName, 'Teh Masak');
    expect(shortages.first.unit, 'liter');
    expect(shortages.first.needed, closeTo(1.2, 1e-9));
    expect(shortages.first.available, 0.5);
    expect(shortages.first.missing, closeTo(0.7, 1e-9));
  });

  test('tidak ada shortage saat stok cukup', () {
    // Seed Teh Masak 0 L -> isi 5 L supaya cukup untuk 2 cup (0.8 L).
    stockByName['Teh Masak'] = const StockItem(
      name: 'Teh Masak',
      unit: 'liter',
      qty: 5,
      lowThreshold: 0,
    );
    final cart = cartOf([(manggo.variants.first, 2)]);
    expect(findShortages(cart, recipes, stockByName), isEmpty);
  });

  test('hanya Cup 22oz yang dipakai (tidak ada Cup 16oz)', () {
    final cart = cartOf([(manggo.variants.first, 1)]);
    final d = computeDeductions(cart, recipes, stockByName);
    expect(d['Cup 22oz'], 1);
    expect(d.containsKey('Cup 16oz'), isFalse);
  });

  test('topping memotong stok: 1 cup +Boba +Selasih, qty 2', () {
    // Batch C1: tiap topping = 1 porsi per cup. 2 cup dengan Boba
    // + Selasih -> Boba 2 porsi, Selasih 2 porsi (di samping resep).
    final cart = [
      CartItem(
        product: manggo,
        variant: manggo.variants.first,
        qty: 2,
        modifiers: const [
          Modifier(name: 'Normal', kind: 'gula'),
          Modifier(name: 'Es Normal', kind: 'es'),
          Modifier(name: 'Boba', kind: 'topping', priceDelta: 3000),
          Modifier(name: 'Selasih', kind: 'topping', priceDelta: 1000),
        ],
      ),
    ];
    final d = computeDeductions(cart, recipes, stockByName);
    expect(d['Boba'], 2);
    expect(d['Selasih'], 2);
    // Resep tetap jalan: Teh Masak 0.4 L x 2 cup.
    expect(d['Teh Masak'], closeTo(0.8, 1e-9));
    expect(d['Cup 22oz'], 2);
  });

  test('topping tanpa bahan stok dilewati (tidak gagal)', () {
    // Boba dihapus dari stok (mis. bahan dihapus Owner) -> deduksi
    // Boba dilewati, bahan lain tetap dihitung.
    stockByName.remove('Boba');
    final cart = [
      CartItem(
        product: manggo,
        variant: manggo.variants.first,
        qty: 1,
        modifiers: const [
          Modifier(name: 'Boba', kind: 'topping', priceDelta: 3000),
        ],
      ),
    ];
    final d = computeDeductions(cart, recipes, stockByName);
    expect(d.containsKey('Boba'), isFalse);
    expect(d['Teh Masak'], closeTo(0.4, 1e-9));
  });

  test('seed resep mencakup semua 20 produk x 1 varian (22oz)', () {
    final menu = seedMenu();
    expect(menu, hasLength(20));
    for (final p in menu) {
      for (final v in p.variants) {
        final lines = recipes[v.id];
        expect(lines, isNotNull, reason: 'resep ${v.id} hilang');
        expect(lines, isNotEmpty);
        // Satu bahan max 1x per varian.
        final names = lines!.map((l) => l.stockName).toList();
        expect(names.toSet(), hasLength(names.length));
        // Semua bahan resep harus ada di seedStock.
        for (final l in lines) {
          expect(stockByName.containsKey(l.stockName), isTrue,
              reason: '${l.stockName} tidak ada di seedStock');
          expect(l.qty, greaterThan(0));
        }
      }
    }
  });
}
