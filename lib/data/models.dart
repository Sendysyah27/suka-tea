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

  /// Kesamaan nilai (bukan identitas): dipakai Set<Modifier> di sheet
  /// opsi produk — topping dari ToppingService dibuat baru tiap baca,
  /// jadi contains() harus membandingkan isi, bukan instance.
  @override
  bool operator ==(Object other) =>
      other is Modifier &&
      other.name == name &&
      other.kind == kind &&
      other.priceDelta == priceDelta;

  @override
  int get hashCode => Object.hash(name, kind, priceDelta);

  factory Modifier.fromJson(Map<String, dynamic> json) => Modifier(
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        priceDelta: (json['priceDelta'] as num? ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind,
        'priceDelta': priceDelta,
      };
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

  /// "Es Teh Lemon Reguler" (tanpa modifier).
  String get nameText => '${product.name} ${variant.name}';

  /// "(Normal, Es Normal)" — topping ditulis "+Nama"
  /// ("(Normal, Es Normal, +Boba)"). Kosong bila tanpa modifier.
  String get modifierText {
    if (modifiers.isEmpty) return '';
    final parts = modifiers.map(
      (m) => m.kind == 'topping' ? '+${m.name}' : m.name,
    );
    return '(${parts.join(', ')})';
  }

  String get label =>
      modifiers.isEmpty ? nameText : '$nameText $modifierText';

  /// Serialisasi untuk order tertahan (HeldOrders.itemsJson).
  /// Produk direkonstruksi dengan satu varian (varian yang ditahan)
  /// — cukup untuk keranjang, struk, dan deduksi stok (resep memakai
  /// variant.id; harga memakai variant.price + delta modifier).
  Map<String, dynamic> toJson() => {
        'productId': product.id,
        'productName': product.name,
        'productCategory': product.category,
        'photoUrl': product.photoUrl,
        'variantId': variant.id,
        'variantName': variant.name,
        'variantPrice': variant.price,
        'qty': qty,
        'modifiers': modifiers.map((m) => m.toJson()).toList(),
      };

  factory CartItem.fromJson(Map<String, dynamic> json) {
    final variant = ProductVariant(
      id: json['variantId'] as String? ?? '',
      name: json['variantName'] as String? ?? 'Reguler',
      price: (json['variantPrice'] as num? ?? 0).toInt(),
    );
    final product = Product(
      id: json['productId'] as String? ?? '',
      name: json['productName'] as String? ?? '',
      category: json['productCategory'] as String? ?? '',
      photoUrl: json['photoUrl'] as String?,
      variants: [variant],
    );
    return CartItem(
      product: product,
      variant: variant,
      qty: (json['qty'] as num? ?? 1).toInt(),
      modifiers: (json['modifiers'] as List<dynamic>? ?? const [])
          .map((e) => Modifier.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class StockItem {
  const StockItem({
    required this.name,
    required this.unit,
    required this.qty,
    required this.lowThreshold,
    this.costPerUnit = -1,
  });

  final String name;
  final String unit;
  final double qty;
  final double lowThreshold;

  /// Harga bahan per satuan (rupiah) — DITENTUKAN Owner di tab Stok
  /// (Batch C1b). -1 = belum diatur (HPP bahan itu dihitung Rp0);
  /// 0 = Owner sengaja mengeset gratis — backfill tidak menimpanya.
  /// Nilai awal dari seedStockCostPerUnit (backfill saat init).
  final double costPerUnit;

  bool get isLow => qty <= lowThreshold;

  StockItem copyWith({
    String? name,
    String? unit,
    double? qty,
    double? lowThreshold,
    double? costPerUnit,
  }) =>
      StockItem(
        name: name ?? this.name,
        unit: unit ?? this.unit,
        qty: qty ?? this.qty,
        lowThreshold: lowThreshold ?? this.lowThreshold,
        costPerUnit: costPerUnit ?? this.costPerUnit,
      );
}

/// Satu baris struk — dipakai halaman struk, share teks, dan PDF.
/// Dibuat dari CartItem (kasir) atau langsung dari SaleItem (riwayat).
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.modifierText,
    required this.qty,
    required this.unitPrice,
  });

  final String name; // "Es Teh Lemon Reguler"
  final String modifierText; // "(Normal, Es Normal)" atau ''
  final int qty;
  final int unitPrice;

  int get total => qty * unitPrice;

  factory ReceiptLine.fromCartItem(CartItem item) => ReceiptLine(
        name: item.nameText,
        modifierText: item.modifierText,
        qty: item.qty,
        unitPrice: item.unitPrice,
      );
}
