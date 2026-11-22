import 'models.dart';

/// SEED / CONTOH — BUKAN data final.
/// Menu, harga, dan foto produk WAJIB bisa di-custom Owner di dalam app
/// (Kelola Menu). Seed ini hanya supaya layar Kasir bisa dites sebelum
/// proyek Supabase + data outlet dibuat.
const List<Modifier> gulaOptions = [
  Modifier(name: 'Normal', kind: 'gula'),
  Modifier(name: 'Kurang Manis', kind: 'gula'),
  Modifier(name: 'Tanpa Gula', kind: 'gula'),
  Modifier(name: 'Extra Manis', kind: 'gula'),
];

const List<Modifier> esOptions = [
  Modifier(name: 'Es Normal', kind: 'es'),
  Modifier(name: 'Sedikit Es', kind: 'es'),
  Modifier(name: 'Banyak Es', kind: 'es'),
];

const List<Modifier> toppingOptions = [
  Modifier(name: 'Boba', kind: 'topping', priceDelta: 3000),
  Modifier(name: 'Jelly', kind: 'topping', priceDelta: 2000),
  Modifier(name: 'Selasih', kind: 'topping', priceDelta: 1000),
];

List<Product> seedMenu() {
  Product p(String id, String name, String cat, int reg, int jumbo) =>
      Product(
        id: id,
        name: name,
        category: cat,
        variants: [
          ProductVariant(id: '${id}_r', name: 'Reguler', sizeOz: 16, price: reg),
          ProductVariant(id: '${id}_j', name: 'Jumbo', sizeOz: 22, price: jumbo),
        ],
      );

  return [
    p('teh-manis', 'Es Teh Manis', 'Teh Klasik', 3000, 5000),
    p('teh-tawar', 'Es Teh Tawar', 'Teh Klasik', 3000, 5000),
    p('teh-melati', 'Es Teh Melati', 'Teh Klasik', 4000, 6000),
    p('teh-lemon', 'Es Teh Lemon', 'Teh Buah', 5000, 7000),
    p('teh-hijau', 'Es Teh Hijau', 'Teh Buah', 6000, 8000),
    p('teh-susu', 'Es Teh Susu', 'Teh Susu', 8000, 10000),
    p('teh-tarik', 'Es Teh Tarik', 'Teh Susu', 8000, 10000),
    p('teh-boba', 'Es Teh Boba', 'Teh Susu', 10000, 12000),
  ];
}

List<StockItem> seedStock() => const [
      StockItem(name: 'Teh', unit: 'kg', qty: 2.5, lowThreshold: 1),
      StockItem(name: 'Gula', unit: 'kg', qty: 5, lowThreshold: 2),
      StockItem(name: 'Cup 16oz', unit: 'pcs', qty: 120, lowThreshold: 50),
      StockItem(name: 'Cup 22oz', unit: 'pcs', qty: 80, lowThreshold: 50),
      StockItem(name: 'Es batu', unit: 'kg', qty: 10, lowThreshold: 5),
      StockItem(name: 'Sedotan', unit: 'pcs', qty: 200, lowThreshold: 100),
    ];
