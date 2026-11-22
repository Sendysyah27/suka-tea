// Model domain SUKA TEA. Uang = integer rupiah.

enum PaymentMethod { tunai, transfer, qris, qrisManual, ewallet }

extension PaymentMethodX on PaymentMethod {
  String get label => switch (this) {
        PaymentMethod.tunai => 'Tunai',
        PaymentMethod.transfer => 'Transfer',
        PaymentMethod.qris => 'QRIS',
        PaymentMethod.qrisManual => 'QRIS (manual)',
        PaymentMethod.ewallet => 'E-Wallet',
      };

  /// Cashless = semua kecuali tunai. Dipakai laporan cash s.d. cashless.
  bool get isCashless => this != PaymentMethod.tunai;
}

class ProductVariant {
  const ProductVariant({
    required this.id,
    required this.name,
    this.sizeOz,
    required this.price,
    this.cost = 0,
  });

  final String id;
  final String name; // Reguler / Jumbo
  final int? sizeOz;
  final int price; // harga jual (rupiah)
  final int cost; // HPP (rupiah) — hanya Owner, jangan tampil ke Kasir
}

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.category,
    this.photoUrl,
    required this.variants,
    this.isActive = true,
  });

  final String id;
  final String name;
  final String category;
  final String? photoUrl;
  final List<ProductVariant> variants;
  final bool isActive;

  ProductVariant get reguler => variants.first;
}

class Modifier {
  const Modifier({
    required this.name,
    required this.kind, // gula | es | topping
    this.priceDelta = 0,
  });

  final String name;
  final String kind;
  final int priceDelta;
}

class CartItem {
  CartItem({
    required this.product,
    required this.variant,
    this.qty = 1,
    this.modifiers = const [],
  });

  final Product product;
  final ProductVariant variant;
  int qty;
  final List<Modifier> modifiers;

  int get unitPrice =>
      variant.price + modifiers.fold(0, (s, m) => s + m.priceDelta);
  int get total => unitPrice * qty;

  String get label {
    final mods = modifiers.isEmpty
        ? ''
        : ' (${modifiers.map((m) => m.name).join(', ')})';
    return '${product.name} ${variant.name}$mods';
  }
}

class StockItem {
  const StockItem({
    required this.name,
    required this.unit,
    required this.qty,
    required this.lowThreshold,
  });

  final String name;
  final String unit;
  final double qty;
  final double lowThreshold;

  bool get isLow => qty <= lowThreshold;
}
