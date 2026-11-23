import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/recipe_logic.dart';
import 'package:suka_tea/data/sale_history.dart';

SaleRecord sale({
  required int total,
  required List<SaleItem> items,
  PaymentMethod method = PaymentMethod.tunai,
  bool isVoid = false,
}) =>
    SaleRecord(
      id: 'test-void-$total-${items.length}-$isVoid',
      createdAt: DateTime(2026, 11, 22, 10, 0),
      items: items,
      total: total,
      method: method,
      paid: total,
      change: 0,
      isVoid: isVoid,
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

  test('computeDailyStats: transaksi void dikecualikan', () {
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
        isVoid: true,
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
    expect(stats.omzet, 16000);
    expect(stats.txnCount, 1);
    expect(stats.cups, 2);
    expect(stats.avgPerTxn, 16000);
    expect(stats.hppEstimate, 4300);
    expect(stats.byMethod[PaymentMethod.tunai], 16000);
  });

  test('computeDailyStats: semua void = semua nol', () {
    final sales = [
      sale(
        total: 5000,
        isVoid: true,
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
    expect(stats.omzet, 0);
    expect(stats.txnCount, 0);
    expect(stats.cups, 0);
    expect(stats.avgPerTxn, 0);
    expect(stats.hppEstimate, 0);
    expect(stats.labaEstimate, 0);
  });

  test('topProducts: transaksi void dikecualikan', () {
    final sales = [
      sale(
        total: 15000,
        items: [
          const SaleItem(
            productId: 'a',
            productName: 'Es Teh Lemon',
            variantId: 'a_r',
            variantName: 'Reguler',
            qty: 3,
            unitPrice: 5000,
          ),
        ],
      ),
      sale(
        total: 40000,
        isVoid: true,
        items: [
          const SaleItem(
            productId: 'b',
            productName: 'Manggo Milktea',
            variantId: 'b_r',
            variantName: 'Reguler',
            qty: 5,
            unitPrice: 8000,
          ),
        ],
      ),
    ];
    final top = topProducts(sales);
    expect(top, hasLength(1));
    expect(top[0].name, 'Es Teh Lemon');
    expect(top[0].qty, 3);
  });

  test('SaleRecord: default tanpa diskon + tanpa void', () {
    final record = SaleRecord(
      id: 'x',
      createdAt: DateTime(2026, 11, 23),
      items: const [],
      total: 0,
      method: PaymentMethod.tunai,
      paid: 0,
      change: 0,
    );
    expect(record.discount, 0);
    expect(record.isVoid, false);
    expect(record.subtotal, 0);
  });

  test('SaleRecord copyWith: tandai void tanpa ubah lain', () {
    final record = SaleRecord(
      id: 'x',
      createdAt: DateTime(2026, 11, 23),
      items: const [],
      total: 9000,
      method: PaymentMethod.qris,
      paid: 9000,
      change: 0,
      discount: 1000,
    );
    final voided = record.copyWith(isVoid: true);
    expect(voided.isVoid, true);
    expect(voided.total, 9000);
    expect(voided.discount, 1000);
    expect(voided.subtotal, 10000);
    expect(record.isVoid, false);
  });
}
