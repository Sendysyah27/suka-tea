import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/recipe_logic.dart';
import 'package:suka_tea/data/sale_history.dart';

/// Split payment di riwayat + statistik (Batch C2).
/// Omzet dihitung SATU kali per transaksi (tidak dobel ke QRIS +
/// tunai); kas laci hanya menghitung bagian tunai yang tinggal.
SaleRecord sale({
  required int total,
  required List<SaleItem> items,
  PaymentMethod method = PaymentMethod.tunai,
  int paid = 0,
  int qrisAmount = 0,
  int cashAmount = 0,
}) =>
    SaleRecord(
      id: 'split-test-$total-${method.name}',
      createdAt: DateTime(2026, 11, 23, 10, 0),
      items: items,
      total: total,
      method: method,
      paid: paid == 0 ? total : paid,
      change: paid == 0 ? 0 : paid - total,
      qrisAmount: qrisAmount,
      cashAmount: cashAmount,
    );

const _items = [
  SaleItem(
    productId: 'es-teh-jumbo',
    productName: 'Es Teh Jumbo',
    variantId: 'es-teh-jumbo_22oz',
    variantName: '22oz',
    qty: 2,
    unitPrice: 3000,
  ),
];

void main() {
  group('SaleRecord.cashInDrawer', () {
    test('tunai: seluruh total tinggal di laci', () {
      expect(sale(total: 20000, items: _items).cashInDrawer, 20000);
    });

    test('qris: tidak ada tunai di laci', () {
      expect(
        sale(total: 20000, method: PaymentMethod.qris, items: _items)
            .cashInDrawer,
        0,
      );
    });

    test('split: hanya total - bagian QRIS yang tinggal di laci', () {
      expect(
        sale(
          total: 21000,
          method: PaymentMethod.split,
          paid: 21000,
          qrisAmount: 10000,
          cashAmount: 11000,
          items: _items,
        ).cashInDrawer,
        11000,
      );
    });

    test('split dengan tunai lebih bayar: kembalian tidak menambah laci',
        () {
      // Total 21000, QRIS 10000, tunai diterima 15000 (kembalian 4000)
      // -> yang tinggal di laci tetap 11000, bukan 15000.
      expect(
        sale(
          total: 21000,
          method: PaymentMethod.split,
          paid: 25000,
          qrisAmount: 10000,
          cashAmount: 15000,
          items: _items,
        ).cashInDrawer,
        11000,
      );
    });

    test('transfer / e-wallet: tidak ada tunai di laci', () {
      expect(
        sale(total: 20000, method: PaymentMethod.transfer, items: _items)
            .cashInDrawer,
        0,
      );
      expect(
        sale(total: 20000, method: PaymentMethod.ewallet, items: _items)
            .cashInDrawer,
        0,
      );
    });
  });

  group('computeDailyStats dengan split', () {
    test('omzet dihitung sekali; byMethod[split] = total', () {
      final sales = [
        sale(total: 16000, items: _items),
        sale(
          total: 21000,
          method: PaymentMethod.split,
          paid: 21000,
          qrisAmount: 10000,
          cashAmount: 11000,
          items: _items,
        ),
      ];
      final stats = computeDailyStats(
        sales,
        const <String, List<RecipeLine>>{},
        const <String, double>{},
      );
      expect(stats.omzet, 37000);
      expect(stats.txnCount, 2);
      expect(stats.byMethod[PaymentMethod.tunai], 16000);
      expect(stats.byMethod[PaymentMethod.split], 21000);
      // Tidak dobel ke QRIS: byMethod[qris] tetap kosong.
      expect(stats.byMethod[PaymentMethod.qris], isNull);
    });
  });

  group('SaleRecord JSON split', () {
    test('toJson/fromJson mempertahankan bagian split + method', () {
      final record = sale(
        total: 21000,
        method: PaymentMethod.split,
        paid: 25000,
        qrisAmount: 10000,
        cashAmount: 15000,
        items: _items,
      );
      final restored = SaleRecord.fromJson(record.toJson());
      expect(restored.method, PaymentMethod.split);
      expect(restored.qrisAmount, 10000);
      expect(restored.cashAmount, 15000);
      expect(restored.paid, 25000);
      expect(restored.change, 4000);
    });

    test('data lama tanpa qrisAmount/cashAmount -> default 0', () {
      final restored = SaleRecord.fromJson({
        'id': 'lama',
        'createdAt': DateTime(2026, 11, 22, 10, 0).toIso8601String(),
        'items': [],
        'total': 9000,
        'method': 'tunai',
        'paid': 9000,
        'change': 0,
        'discount': 0,
        'isVoid': false,
        'outletId': '00000000-0000-0000-0000-000000000001',
      });
      expect(restored.qrisAmount, 0);
      expect(restored.cashAmount, 0);
      expect(restored.cashInDrawer, 9000);
    });

    test('method "split" dari JSON lama yang tidak dikenal -> tunai', () {
      // fromJson memakai firstWhere orElse tunai untuk nama yang
      // tidak dikenal — perilaku lama dipertahankan.
      final restored = SaleRecord.fromJson({
        'id': 'aneh',
        'createdAt': DateTime(2026, 11, 22, 10, 0).toIso8601String(),
        'items': [],
        'total': 9000,
        'method': 'tidak-ada',
        'paid': 9000,
        'change': 0,
      });
      expect(restored.method, PaymentMethod.tunai);
    });
  });
}
