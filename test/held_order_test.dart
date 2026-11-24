import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/held_order_service.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/seed_menu.dart';

void main() {
  test('CartItem toJson/fromJson: round-trip utuh', () {
    final manggo =
        seedMenu().firstWhere((p) => p.id == 'manggo-milktea');
    final original = CartItem(
      product: manggo,
      variant: manggo.variants.first,
      qty: 2,
      modifiers: const [
        Modifier(name: 'Kurang Manis', kind: 'gula'),
        Modifier(name: 'Sedikit Es', kind: 'es'),
        Modifier(name: 'Boba', kind: 'topping', priceDelta: 3000),
      ],
    );
    final restored = CartItem.fromJson(original.toJson());
    expect(restored.product.id, 'manggo-milktea');
    expect(restored.product.name, 'Manggo Milktea');
    expect(restored.variant.id, 'manggo-milktea_22oz');
    expect(restored.variant.name, '22oz');
    expect(restored.variant.price, 8000);
    expect(restored.qty, 2);
    expect(restored.modifiers, hasLength(3));
    expect(restored.modifiers[0].name, 'Kurang Manis');
    expect(restored.modifiers[0].kind, 'gula');
    expect(restored.modifiers[2].name, 'Boba');
    expect(restored.modifiers[2].kind, 'topping');
    expect(restored.modifiers[2].priceDelta, 3000);
    // Harga + total ikut pulih (untuk struk + deduksi stok).
    expect(restored.unitPrice, 11000);
    expect(restored.total, 22000);
    expect(restored.nameText, original.nameText);
    expect(restored.modifierText, original.modifierText);
  });

  test('CartItem fromJson: field hilang tidak crash (default aman)', () {
    final restored = CartItem.fromJson({});
    expect(restored.product.id, '');
    expect(restored.variant.id, '');
    expect(restored.qty, 1);
    expect(restored.modifiers, isEmpty);
    expect(restored.unitPrice, 0);
  });

  test('HeldOrder: subtotal, cup, ringkasan', () {
    final manggo =
        seedMenu().firstWhere((p) => p.id == 'manggo-milktea');
    final lemon = seedMenu().firstWhere((p) => p.id == 'es-teh-lemon');
    final order = HeldOrder(
      id: 'test-1',
      label: 'Pending 1 • 14:05',
      items: [
        CartItem(
          product: manggo,
          variant: manggo.variants.first,
          qty: 2,
          modifiers: const [
            Modifier(name: 'Boba', kind: 'topping', priceDelta: 3000),
          ],
        ),
        CartItem(product: lemon, variant: lemon.variants.last, qty: 1),
      ],
      createdAt: DateTime(2026, 11, 23, 14, 5),
    );
    // Manggo 22oz 8000 + Boba 3000 = 11000 x 2 = 22000;
    // Lemon 22oz 5000 x 1 = 5000.
    expect(order.subtotal, 27000);
    expect(order.count, 3);
    expect(order.summary, '2x Manggo Milktea, 1x Es Teh Lemon');
  });

  group('HeldOrderService.restore — normalisasi varian lama (WS7)', () {
    setUpAll(() async {
      // Pola yang sama dengan gerai_monitor_sync_test: Drift butuh
      // path_provider yang TIDAK ada di test env — mock ke folder
      // temp sungguhan supaya SQLite benar-benar terbuka di CI.
      TestWidgetsFlutterBinding.ensureInitialized();
      final dir =
          Directory.systemTemp.createTempSync('suka-tea-held-order-test');
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
      await HeldOrderService.instance.init();
    });

    test('varian lama _r dinormalisasi ke 22oz (harga + modifier ikut)', () async {
      final manggo =
          seedMenu().firstWhere((p) => p.id == 'manggo-milktea');
      const legacyReguler = ProductVariant(
        id: 'manggo-milktea_r',
        name: 'Reguler',
        sizeOz: 16,
        price: 8000,
      );
      final order = await HeldOrderService.instance.hold([
        CartItem(
          product: manggo,
          variant: legacyReguler,
          qty: 2,
          modifiers: const [
            Modifier(name: 'Boba', kind: 'topping', priceDelta: 3000),
          ],
        ),
      ]);
      final restored = await HeldOrderService.instance.restore(order.id);
      expect(restored, isNotNull);
      expect(restored, hasLength(1));
      expect(restored!.first.variant.id, 'manggo-milktea_22oz');
      expect(restored.first.variant.name, '22oz');
      expect(restored.first.variant.price, 8000);
      expect(restored.first.qty, 2);
      expect(restored.first.modifiers, hasLength(1));
      expect(restored.first.modifiers.first.name, 'Boba');
      expect(restored.first.unitPrice, 11000);
    });

    test('varian 22oz saat ini lolos tanpa perubahan', () async {
      final manggo =
          seedMenu().firstWhere((p) => p.id == 'manggo-milktea');
      final order = await HeldOrderService.instance.hold([
        CartItem(product: manggo, variant: manggo.variants.first, qty: 1),
      ]);
      final restored = await HeldOrderService.instance.restore(order.id);
      expect(restored, isNotNull);
      expect(restored!.first.variant.id, 'manggo-milktea_22oz');
      expect(restored.first.variant.price, 8000);
    });

    test('produk yang sudah tidak ada di menu dibiarkan apa adanya',
        () async {
      const hilang = Product(
        id: 'produk-hilang',
        name: 'Produk Hilang',
        category: 'Best Seller',
        variants: [
          ProductVariant(id: 'produk-hilang_r', name: 'Reguler', price: 6000),
        ],
      );
      final order = await HeldOrderService.instance.hold([
        CartItem(
          product: hilang,
          variant: const ProductVariant(
            id: 'produk-hilang_r',
            name: 'Reguler',
            price: 6000,
          ),
          qty: 1,
        ),
      ]);
      final restored = await HeldOrderService.instance.restore(order.id);
      expect(restored, isNotNull);
      expect(restored!.first.product.id, 'produk-hilang');
      expect(restored.first.variant.id, 'produk-hilang_r');
      expect(restored.first.variant.price, 6000);
    });

    test('restore id tidak ada = null', () async {
      expect(
        await HeldOrderService.instance.restore('tidak-ada'),
        isNull,
      );
    });
  });
}
