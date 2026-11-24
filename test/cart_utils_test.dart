import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/cart_utils.dart';
import 'package:suka_tea/data/models.dart';

/// Helper keranjang Kasir (Batch C5): badge qty per produk +
/// edit baris keranjang (ganti varian/modifier, qty dipertahankan,
/// duplikat digabung).
///
/// Batch C8.2 WS7: tiap produk hanya 1 varian 22oz. Helper-nya
/// sendiri tetap generik (tidak peduli jumlah varian), jadi fixture
/// di sini 1 varian; satu test varian lama dipertahankan untuk
/// membuktikan utility tidak crash pada data lama (_r/_j).

const _v22 = ProductVariant(id: 'lemon_22oz', name: '22oz', price: 5000);

const _lemon = Product(
  id: 'es-teh-lemon',
  name: 'Es Teh Lemon',
  category: 'Best Seller',
  variants: [_v22],
);

const _susu = Product(
  id: 'es-teh-susu',
  name: 'Es Teh Susu',
  category: 'Best Seller',
  variants: [
    ProductVariant(id: 'susu_22oz', name: '22oz', price: 5000),
  ],
);

const _gulaNormal = Modifier(name: 'Normal', kind: 'gula');
const _esNormal = Modifier(name: 'Es Normal', kind: 'es');
const _boba = Modifier(name: 'Boba', kind: 'topping', priceDelta: 3000);
const _jelly = Modifier(name: 'Jelly', kind: 'topping', priceDelta: 2000);

CartItem _item(
  Product product,
  ProductVariant variant,
  int qty, [
  List<Modifier> modifiers = const [_gulaNormal, _esNormal],
]) =>
    CartItem(
      product: product,
      variant: variant,
      qty: qty,
      modifiers: modifiers,
    );

void main() {
  group('cartQtyByProduct (badge kartu produk)', () {
    test('keranjang kosong = map kosong', () {
      expect(cartQtyByProduct([]), isEmpty);
    });

    test('satu produk, satu varian', () {
      final map = cartQtyByProduct([_item(_lemon, _v22, 2)]);
      expect(map, {'es-teh-lemon': 2});
    });

    test('dua baris produk yang sama (beda topping) DIGABUNG', () {
      final map = cartQtyByProduct([
        _item(_lemon, _v22, 2),
        _item(
          _lemon,
          _v22,
          3,
          [_gulaNormal, _esNormal, _boba],
        ),
      ]);
      expect(map, {'es-teh-lemon': 5});
    });

    test('produk berbeda dihitung terpisah', () {
      final map = cartQtyByProduct([
        _item(_lemon, _v22, 2),
        _item(_susu, _susu.variants.first, 1),
      ]);
      expect(map, {'es-teh-lemon': 2, 'es-teh-susu': 1});
    });
  });

  group('sameModifiers', () {
    test('sama persis (urutan berbeda tetap sama)', () {
      expect(
        sameModifiers(
          [_gulaNormal, _esNormal, _boba],
          [_boba, _esNormal, _gulaNormal],
        ),
        isTrue,
      );
    });

    test('beda topping = tidak sama', () {
      expect(
        sameModifiers(
          [_gulaNormal, _esNormal, _boba],
          [_gulaNormal, _esNormal, _jelly],
        ),
        isFalse,
      );
    });

    test('beda panjang = tidak sama', () {
      expect(
        sameModifiers([_gulaNormal], [_gulaNormal, _esNormal]),
        isFalse,
      );
    });
  });

  group('replaceCartItem (edit baris keranjang)', () {
    test('ganti topping, qty dipertahankan, baris tidak nambah', () {
      final cart = [_item(_lemon, _v22, 1)];
      final updated = replaceCartItem(
        cart,
        0,
        _v22,
        [_gulaNormal, _esNormal, _boba],
      );
      expect(updated.length, 1);
      expect(updated.first.variant.id, 'lemon_22oz');
      expect(updated.first.unitPrice, 5000 + 3000);
      expect(updated.first.qty, 1);
    });

    test('edit jadi duplikat baris lain = qty digabung, baris hilang', () {
      final cart = [
        _item(_lemon, _v22, 2),
        _item(_lemon, _v22, 3, [_gulaNormal, _esNormal, _boba]),
      ];
      final updated = replaceCartItem(
        cart,
        0,
        _v22,
        [_gulaNormal, _esNormal, _boba],
      );
      expect(updated.length, 1);
      expect(updated.first.variant.id, 'lemon_22oz');
      expect(updated.first.qty, 5);
    });

    test('ganti varian (data lama _r/_j) tetap didukung utility', () {
      // Utility generik — tidak peduli jumlah varian. Data lama
      // (mis. order Pending sebelum WS7) masih bisa diedit.
      const legacyJumbo =
          ProductVariant(id: 'lemon_j', name: 'Jumbo', price: 7000);
      final cart = [_item(_lemon, _v22, 2)];
      final updated = replaceCartItem(
        cart,
        0,
        legacyJumbo,
        [_gulaNormal, _esNormal],
      );
      expect(updated.length, 1);
      expect(updated.first.variant.id, 'lemon_j');
      expect(updated.first.qty, 2);
    });

    test('list lama tidak diubah', () {
      final cart = [_item(_lemon, _v22, 2)];
      replaceCartItem(cart, 0, _v22, [_gulaNormal, _esNormal, _boba]);
      expect(cart.first.variant.id, 'lemon_22oz');
      expect(cart.first.qty, 2);
      expect(cart.first.modifiers, hasLength(2));
    });

    test('index di luar rentang = salinan tanpa perubahan', () {
      final cart = [_item(_lemon, _v22, 2)];
      final updated = replaceCartItem(cart, 5, _v22, [_gulaNormal, _esNormal]);
      expect(updated.length, 1);
      expect(updated.first.variant.id, 'lemon_22oz');
    });
  });
}
