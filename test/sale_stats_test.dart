import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/recipe_logic.dart';
import 'package:suka_tea/data/sale_history.dart';

SaleRecord sale({
  required int total,
  required List<SaleItem> items,
  PaymentMethod method = PaymentMethod.tunai,
  int paid = 0,
}) =>
    SaleRecord(
      id: 'test-$total-${items.length}',
      createdAt: DateTime(2026, 11, 22, 10, 0),
      items: items,
      total: total,
      method: method,
      paid: paid == 0 ? total : paid,
      change: paid == 0 ? 0 : paid - total,
    );

void main() {
  final recipes = <String, List<RecipeLine>>{
    'manggo-milktea_r': [
      const RecipeLine(stockName: 'Teh', qty: 0.010),
      const RecipeLine(stockName: 'Gula', qty: 0.025),
      const RecipeLine(stockName: 'Cup 16oz', qty: 1),
    ],
  };
  const costs = <String, double>{
    'Teh': 120000,
    'Gula': 18000,
    'Cup 16oz': 500,
  };

  test('estimateHppForItems: 2x Manggo Reguler', () {
    final items = [
      const SaleItem(
        productId: 'manggo-milktea',
        productName: 'Manggo Milktea',
        variantId: 'manggo-milktea_r',
        variantName: 'Reguler',
        qty: 2,
        unitPrice: 8000,
      ),
    ];
    // Per cup: 0.010*120000 + 0.025*18000 + 1*500 = 1200+450+500 = 2150.
    expect(estimateHppForItems(items, recipes, costs), 4300);
  });

  test('estimateHppForItems: varian tanpa resep = Rp0', () {
    final items = [
      const SaleItem(
        productId: 'baru',
        productName: 'Produk Baru',
        variantId: 'baru_r',
        variantName: 'Reguler',
        qty: 3,
        unitPrice: 5000,
      ),
    ];
    expect(estimateHppForItems(items, recipes, costs), 0);
  });

  test('computeDailyStats: omzet, cup, rata-rata, HPP, laba, per cara bayar',
      () {
    final sales = [
      sale(
        total: 16000,
        items: [
          const SaleItem(
            productId: 'manggo-milktea',
            productName: 'Manggo Milktea',
            variantId: 'manggo-milktea_r',
            variantName: 'Reguler',
            qty: 2,
            unitPrice: 8000,
          ),
        ],
      ),
      sale(
        total: 5000,
        method: PaymentMethod.qris,
        items: [
          const SaleItem(
            productId: 'es-teh-lemon',
            productName: 'Es Teh Lemon',
            variantId: 'es-teh-lemon_r',
            variantName: 'Reguler',
            qty: 1,
            unitPrice: 5000,
          ),
        ],
      ),
    ];
    final stats = computeDailyStats(sales, recipes, costs);
    expect(stats.omzet, 21000);
    expect(stats.txnCount, 2);
    expect(stats.cups, 3);
    expect(stats.avgPerTxn, 10500);
    // HPP hanya dari Manggo (2150/cup x 2 = 4300); Lemon tanpa resep = 0.
    expect(stats.hppEstimate, 4300);
    expect(stats.labaEstimate, 21000 - 4300);
    expect(stats.byMethod[PaymentMethod.tunai], 16000);
    expect(stats.byMethod[PaymentMethod.qris], 5000);
  });

  test('computeDailyStats: tanpa transaksi = semua nol', () {
    final stats = computeDailyStats([], recipes, costs);
    expect(stats.omzet, 0);
    expect(stats.txnCount, 0);
    expect(stats.cups, 0);
    expect(stats.avgPerTxn, 0);
    expect(stats.hppEstimate, 0);
    expect(stats.labaEstimate, 0);
  });

  test('topProducts: urut cup menurun, top 3', () {
    final sales = [
      sale(
        total: 24000,
        items: [
          const SaleItem(
            productId: 'a',
            productName: 'Es Teh Lemon',
            variantId: 'a_r',
            variantName: 'Reguler',
            qty: 3,
            unitPrice: 5000,
          ),
          const SaleItem(
            productId: 'b',
            productName: 'Manggo Milktea',
            variantId: 'b_r',
            variantName: 'Reguler',
            qty: 1,
            unitPrice: 8000,
          ),
        ],
      ),
      sale(
        total: 10000,
        items: [
          const SaleItem(
            productId: 'a',
            productName: 'Es Teh Lemon',
            variantId: 'a_r',
            variantName: 'Reguler',
            qty: 2,
            unitPrice: 5000,
          ),
        ],
      ),
    ];
    final top = topProducts(sales);
    expect(top.length, 2);
    expect(top[0].name, 'Es Teh Lemon');
    expect(top[0].qty, 5);
    expect(top[1].name, 'Manggo Milktea');
    expect(top[1].qty, 1);
  });
}
