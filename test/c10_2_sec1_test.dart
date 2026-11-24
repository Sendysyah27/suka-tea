// Batch C10.2 (W1–W5) + SEC-1 (R-02/R-05/R-10/R-11) — tes builder.
// Pola setUpAll dari c10_stock_test.dart: path_provider di-mock ke
// folder temp supaya Drift/SQLite benar-benar terbuka, TIDAK fakeAsync.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/c10_models.dart';
import 'package:suka_tea/data/master_sync.dart';
import 'package:suka_tea/data/menu_service.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/data/package_service.dart';
import 'package:suka_tea/data/recipe_logic.dart';
import 'package:suka_tea/data/sale_history.dart';
import 'package:suka_tea/data/stock_service.dart';
import 'package:suka_tea/features/gudang/dashboard_page.dart';
import 'package:suka_tea/features/gudang/package_edit_page.dart';
import 'package:suka_tea/features/kasir/cashier_service.dart';
import 'package:suka_tea/features/laporan/shift_sheets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gerai1 = '00000000-0000-0000-0000-000000000001';
  const gerai3 = '00000000-0000-0000-0000-000000000003';

  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('suka-tea-c102-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        switch (call.method) {
          case 'getTemporaryDirectory':
          case 'getApplicationDocumentsDirectory':
          case 'getApplicationSupportDirectory':
            return dir.path;
          default:
            return null;
        }
      },
    );
    await OutletService.instance.init();
    await StockService.instance.init();
    await MenuService.instance.init();
    await SaleHistoryService.instance.init();
    await PackageService.instance.init();
  });

  StockItem stock(String name, double qty) => StockItem(
        name: name,
        unit: 'liter',
        qty: qty,
        lowThreshold: 0,
        costPerUnit: 0,
        outletId: gerai1,
      );

  Product product(String id, {bool active = true}) => Product(
        id: id,
        name: id,
        category: '',
        variants: [
          ProductVariant(id: '${id}_22oz', name: '22oz', price: 8000),
        ],
        isActive: active,
      );

  group('C10.2 W1 — katalog bahan (gudang kosong)', () {
    test('katalog berisi 14 nama seed walau gudang belum di-seed', () {
      final catalog = StockService.instance.allKnownStockNames;
      expect(StockService.instance.levelsFor(gudangOutletId), isEmpty);
      expect(catalog.length, greaterThanOrEqualTo(14));
      for (final name in <String>[
        'Teh Kering',
        'Teh Masak',
        'Gula',
        'Cup 16oz',
        'Cup 22oz',
        'Es batu',
        'Sedotan',
        'Susu bubuk',
        'Bubuk perasa',
        'Yakult',
        'Lemon',
        'Boba',
        'Jelly',
        'Selasih',
      ]) {
        expect(catalog.containsKey(name), isTrue, reason: name);
      }
      // Prioritas satuan: seed menang.
      expect(catalog['Teh Masak'], 'liter');
      expect(catalog['Boba'], 'porsi');
    });

    testWidgets('Ubah Paket: dropdown memakai katalog, bukan stok gudang',
        (tester) async {
      final packages = PackageService.instance.packages;
      expect(packages.isNotEmpty, isTrue);
      await tester.pumpWidget(
        MaterialApp(home: PackageEditPage(packageId: packages.first.id)),
      );
      await tester.pumpAndSettle();
      // Nama template tampil (bukan label "Bahan") karena value ada
      // di items dropdown (bug B1 sebelumnya: items [] -> label).
      expect(find.text('Teh Kering'), findsWidgets);
      expect(find.text('Teh Masak'), findsWidgets);
      final dropdownCount = find.byWidgetPredicate(
        (w) => w is DropdownButtonFormField<String>,
      );
      expect(dropdownCount, findsNWidgets(14));
      // Paket BARU (kosong): "Tambah bahan" mengambil bahan pertama
      // dari katalog — bukan dari gudang yang kosong. Key beda dari
      // halaman sebelumnya supaya state 14 baris template tidak
      // dipakai ulang oleh pumpWidget (widget sejenis tanpa key
      // di-reuse Flutter).
      await tester.pumpWidget(
        const MaterialApp(home: PackageEditPage(key: ValueKey('baru'))),
      );
      await tester.pumpAndSettle();
      expect(dropdownCount, findsNothing);
      await tester.tap(find.text('Tambah bahan'));
      await tester.pumpAndSettle();
      expect(dropdownCount, findsOneWidget);
      expect(find.text('Boba'), findsWidgets); // pertama terurut
    });
  });

  group('C10.2 W2 — hero laba bersih jujur', () {
    test('HPP belum diatur -> em dash, tanpa angka laba', () {
      final text = heroLabaBersihText(hppUnset: true, labaBersih: 75000);
      expect(text, contains('—'));
      expect(text, isNot(contains('75.000')));
    });

    test('semua biaya diatur -> angka omzet - hpp - pengeluaran', () {
      final text = heroLabaBersihText(hppUnset: false, labaBersih: 75000);
      expect(text, 'laba bersih Rp75.000');
    });
  });

  group('C10.2 W3 — kapasitas serentak (maks satu menu)', () {
    test('Gerai 1: 8 L Teh Masak, 20 menu -> 20 cup (bukan 400)', () {
      final products = List.generate(20, (i) => product('menu-$i'));
      final recipes = <String, List<RecipeLine>>{
        for (final p in products)
          p.variants.first.id: [
            const RecipeLine(stockName: 'Teh Masak', qty: 0.4),
            const RecipeLine(stockName: 'Gula', qty: 0.035),
          ],
      };
      final stok = {
        'Teh Masak': stock('Teh Masak', 8),
        'Gula': stock('Gula', 5),
      };
      expect(totalCapacityCups(products, recipes, stok), 20);
      expect(limitingStockForCapacity(products, recipes, stok), 'Teh Masak');
    });

    test('Gerai 3/4: Teh Masak 0 -> 0 cup + pembatas tetap Teh Masak', () {
      final products = [product('polos')];
      final recipes = <String, List<RecipeLine>>{
        'polos_22oz': [const RecipeLine(stockName: 'Teh Masak', qty: 0.4)],
      };
      final stok = {
        'Teh Masak': const StockItem(
          name: 'Teh Masak',
          unit: 'liter',
          qty: 0,
          lowThreshold: 0,
          outletId: gerai3,
        ),
      };
      expect(totalCapacityCups(products, recipes, stok), 0);
      expect(limitingStockForCapacity(products, recipes, stok), 'Teh Masak');
    });

    test('bahan pembatas lain (Gula 0,35 kg / 0,035) -> 10 cup', () {
      final products = [product('manis')];
      final recipes = <String, List<RecipeLine>>{
        'manis_22oz': [
          const RecipeLine(stockName: 'Teh Masak', qty: 0.4),
          const RecipeLine(stockName: 'Gula', qty: 0.035),
        ],
      };
      final stok = {
        'Teh Masak': stock('Teh Masak', 8),
        'Gula': stock('Gula', 0.35),
      };
      expect(totalCapacityCups(products, recipes, stok), 10);
      expect(limitingStockForCapacity(products, recipes, stok), 'Gula');
    });

    test('tab Stok kasir memakai angka yang sama (totalCapacityCups)', () {
      // StokPage Kasir memanggil totalCapacityCups(products Aktif,
      // recipes, stock) — helper yang sama dengan Dashboard/§6.
      final products = [product('a'), product('b', active: false)];
      final recipes = <String, List<RecipeLine>>{
        'a_22oz': [const RecipeLine(stockName: 'Teh Masak', qty: 0.4)],
        'b_22oz': [const RecipeLine(stockName: 'Teh Masak', qty: 0.1)],
      };
      final stok = {'Teh Masak': stock('Teh Masak', 2)};
      expect(totalCapacityCups(products, recipes, stok), 5);
    });
  });

  group('C10.2 W4 — snapshot penjualan baru pakai 22oz', () {
    test('nama varian lama di menu lokal tidak masuk snapshot baru', () {
      const staleVariant = ProductVariant(
        id: 'taro-milktea_22oz',
        name: 'Reguler', // data basi dari instalasi lama
        price: 8000,
      );
      final item = CartItem(
        product: const Product(
          id: 'taro-milktea',
          name: 'Taro Milktea',
          category: 'Milktea',
          variants: [staleVariant],
        ),
        variant: staleVariant,
        modifiers: [
          const Modifier(name: 'Normal', kind: 'other'),
          const Modifier(name: 'Es Normal', kind: 'other'),
        ],
      );
      // Komposisi name_snapshot = CartItem.label (payload outbox).
      expect(item.label, contains('22oz'));
      expect(item.label, isNot(contains('Reguler')));
      final saleItem = SaleItem.fromCartItem(item);
      expect(saleItem.variantName, '22oz');
      expect(saleItem.variantName, isNot('Reguler'));
    });
  });

  group('C10.2 W5 — nama pembuka shift', () {
    test('Owner tanpa nama sesi -> Owner', () {
      expect(
        resolveShiftOpenerName(cashierId: '', cashierName: '', isOwner: true),
        'Owner',
      );
    });

    test('kasir terdaftar dari registry -> nama asli', () {
      CashierService.instance.rememberCashier(
        id: 'kasir-uuid-1',
        name: 'Sinta',
      );
      expect(
        resolveShiftOpenerName(
          cashierId: 'kasir-uuid-1',
          cashierName: '',
          isOwner: false,
        ),
        'Sinta',
      );
    });

    test('nama sesi menang; tidak ada jalur yang menghasilkan Kasir', () {
      expect(
        resolveShiftOpenerName(
          cashierId: 'kasir-uuid-1',
          cashierName: 'Rizky',
          isOwner: false,
        ),
        'Rizky',
      );
      final unknown = resolveShiftOpenerName(
        cashierId: '',
        cashierName: '',
        isOwner: false,
      );
      expect(unknown, isEmpty);
      expect(shiftOpenerLabel(unknown), '—');
      expect(shiftOpenerLabel(unknown), isNot('Kasir'));
    });
  });

  group('SEC-1 R-10 — cost server 0 -> lokal -1 di dua jalur', () {
    test('baris baru: cost 0 -> -1', () async {
      const outlet = '11111111-1111-1111-1111-111111111111';
      final name = 'Bahan Baru ${DateTime.now().microsecondsSinceEpoch}';
      await StockService.instance.mergePulledStockConfigs([
        MasterChange(
          entity: MasterEntity.stockItemConfig,
          id: '$outlet|$name',
          updatedAt: DateTime.now().toUtc(),
          data: {
            'outlet_id': outlet,
            'name': name,
            'unit': 'pcs',
            'cost_per_unit': 0,
          },
        ),
      ]);
      final item = StockService.instance
          .levelsFor(outlet)
          .where((s) => s.name == name)
          .toList();
      expect(item, hasLength(1));
      expect(item.first.costPerUnit, -1);
    });

    test('baris ada: cost 0 -> -1 (bukan mempertahankan lama)', () async {
      const outlet = '22222222-2222-2222-2222-222222222222';
      final name = 'Bahan Lama ${DateTime.now().microsecondsSinceEpoch}';
      await StockService.instance.ensureStockItem(outlet, name, 'pcs');
      await StockService.instance.setCostFor(outlet, name, 12000);
      await StockService.instance.mergePulledStockConfigs([
        MasterChange(
          entity: MasterEntity.stockItemConfig,
          id: '$outlet|$name|zero',
          updatedAt: DateTime.now().toUtc(),
          data: {
            'outlet_id': outlet,
            'name': name,
            'unit': 'pcs',
            'cost_per_unit': 0,
          },
        ),
      ]);
      final item = StockService.instance
          .levelsFor(outlet)
          .firstWhere((s) => s.name == name);
      expect(item.costPerUnit, -1);
    });
  });
}
