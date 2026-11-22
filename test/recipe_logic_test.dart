import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/recipe_logic.dart';
import 'package:suka_tea/data/seed_menu.dart';
import 'package:suka_tea/data/seed_recipes.dart';

/// Unit test fungsi murni resep (tanpa Flutter/Drift).
/// Angka acuan = seedRecipes() untuk Manggo Milktea:
/// Reguler: Teh 0.010, Gula 0.025, Susu bubuk 0.020, Bubuk perasa 0.015,
///   Cup 16oz 1, Es batu 0.15, Sedotan 1.
/// Jumbo: Teh 0.015, Gula 0.035, Susu bubuk 0.030, Bubuk perasa 0.020,
///   Cup 22oz 1, Es batu 0.20, Sedotan 1.
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

  test('deduction 2x Manggo Reguler + 1x Jumbo', () {
    final cart = cartOf([
      (manggo.variants.first, 2),
      (manggo.variants.last, 1),
    ]);
    final d = computeDeductions(cart, recipes, stockByName);
    expect(d['Teh'], closeTo(0.035, 1e-9));
    expect(d['Gula'], closeTo(0.085, 1e-9));
    expect(d['Susu bubuk'], closeTo(0.070, 1e-9));
    expect(d['Bubuk perasa'], closeTo(0.050, 1e-9));
    expect(d['Cup 16oz'], 2);
    expect(d['Cup 22oz'], 1);
    expect(d['Es batu'], closeTo(0.50, 1e-9));
    expect(d['Sedotan'], 3);
  });

  test('shortage terdeteksi saat stok kurang', () {
    // Teh seed 2.5 kg -> turunkan jadi 0.02 kg (butuh 0.035 kg).
    stockByName['Teh'] =
        const StockItem(name: 'Teh', unit: 'kg', qty: 0.02, lowThreshold: 1);
    final cart = cartOf([
      (manggo.variants.first, 2),
      (manggo.variants.last, 1),
    ]);
    final shortages = findShortages(cart, recipes, stockByName);
    expect(shortages, hasLength(1));
    expect(shortages.first.stockName, 'Teh');
    expect(shortages.first.unit, 'kg');
    expect(shortages.first.needed, closeTo(0.035, 1e-9));
    expect(shortages.first.available, 0.02);
    expect(shortages.first.missing, closeTo(0.015, 1e-9));
  });

  test('tidak ada shortage saat stok cukup', () {
    final cart = cartOf([(manggo.variants.first, 2)]);
    expect(findShortages(cart, recipes, stockByName), isEmpty);
  });

  test('Cup 16oz vs 22oz tidak tertukar', () {
    final regulerOnly = cartOf([(manggo.variants.first, 1)]);
    final dReg = computeDeductions(regulerOnly, recipes, stockByName);
    expect(dReg['Cup 16oz'], 1);
    expect(dReg.containsKey('Cup 22oz'), isFalse);

    final jumboOnly = cartOf([(manggo.variants.last, 1)]);
    final dJum = computeDeductions(jumboOnly, recipes, stockByName);
    expect(dJum['Cup 22oz'], 1);
    expect(dJum.containsKey('Cup 16oz'), isFalse);
  });

  test('seed resep mencakup semua 20 produk x 2 varian', () {
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
