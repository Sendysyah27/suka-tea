import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/stock_service.dart';

void main() {
  group('costsFromLevels', () {
    test('peta biaya dari daftar stok', () {
      const levels = [
        StockItem(
          name: 'Teh',
          unit: 'kg',
          qty: 2.5,
          lowThreshold: 1,
          costPerUnit: 120000,
        ),
        StockItem(
          name: 'Boba',
          unit: 'porsi',
          qty: 50,
          lowThreshold: 10,
        ),
      ];
      final costs = StockService.costsFromLevels(levels);
      expect(costs['Teh'], 120000);
      // Tanpa costPerUnit = -1 (belum diatur) -> HPP dihitung Rp0.
      expect(costs['Boba'], 0);
    });

    test('daftar kosong = peta kosong', () {
      expect(StockService.costsFromLevels(const []), isEmpty);
    });
  });

  group('backfillCosts', () {
    const seed = <String, double>{
      'Teh': 120000,
      'Gula': 18000,
      'Boba': 0,
    };

    test('belum diatur (-1) + seed > 0 = diisi nilai seed', () {
      const levels = [
        StockItem(name: 'Teh', unit: 'kg', qty: 2.5, lowThreshold: 1),
        StockItem(name: 'Gula', unit: 'kg', qty: 5, lowThreshold: 2),
      ];
      final filled = StockService.backfillCosts(levels, seed);
      expect(filled[0].costPerUnit, 120000);
      expect(filled[1].costPerUnit, 18000);
    });

    test('biaya yang Owner sudah isi (> 0) tidak disentuh', () {
      const levels = [
        StockItem(
          name: 'Teh',
          unit: 'kg',
          qty: 2.5,
          lowThreshold: 1,
          costPerUnit: 135000,
        ),
      ];
      final filled = StockService.backfillCosts(levels, seed);
      expect(filled[0].costPerUnit, 135000);
    });

    test('biaya 0 yang Owner isi sengaja (gratis) tidak disentuh', () {
      const levels = [
        StockItem(
          name: 'Teh',
          unit: 'kg',
          qty: 2.5,
          lowThreshold: 1,
          costPerUnit: 0,
        ),
      ];
      final filled = StockService.backfillCosts(levels, seed);
      expect(filled[0].costPerUnit, 0);
    });

    test('topping (seed 0) tetap -1 sampai Owner mengisinya', () {
      const levels = [
        StockItem(name: 'Boba', unit: 'porsi', qty: 50, lowThreshold: 10),
      ];
      final filled = StockService.backfillCosts(levels, seed);
      expect(filled[0].costPerUnit, -1);
    });

    test('bahan tanpa seed tetap -1', () {
      const levels = [
        StockItem(name: 'Bahan Baru', unit: 'kg', qty: 1, lowThreshold: 1),
      ];
      final filled = StockService.backfillCosts(levels, seed);
      expect(filled[0].costPerUnit, -1);
    });

    test('daftar asli tidak diubah', () {
      const levels = [
        StockItem(name: 'Teh', unit: 'kg', qty: 2.5, lowThreshold: 1),
      ];
      StockService.backfillCosts(levels, seed);
      expect(levels[0].costPerUnit, -1);
    });
  });

  group('isValidCost', () {
    test('negatif ditolak, nol dan positif diterima', () {
      expect(StockService.isValidCost(-1), isFalse);
      expect(StockService.isValidCost(0), isTrue);
      expect(StockService.isValidCost(500), isTrue);
    });
  });

  test('StockItem.copyWith mempertahankan biaya', () {
    const item = StockItem(
      name: 'Teh',
      unit: 'kg',
      qty: 2,
      lowThreshold: 1,
      costPerUnit: 120000,
    );
    final changed = item.copyWith(qty: 1);
    expect(changed.costPerUnit, 120000);
    expect(changed.qty, 1);
    expect(changed.name, 'Teh');
  });
}
