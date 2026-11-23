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
    expect(restored.variant.id, 'manggo-milktea_r');
    expect(restored.variant.name, 'Reguler');
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
      label: 'Tahan 1 • 14:05',
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
    // Manggo Reguler 8000 + Boba 3000 = 11000 x 2 = 22000;
    // Lemon Jumbo 7000 x 1 = 7000.
    expect(order.subtotal, 29000);
    expect(order.count, 3);
    expect(order.summary, '2x Manggo Milktea, 1x Es Teh Lemon');
  });
}
