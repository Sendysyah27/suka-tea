import 'models.dart';

/// MENU AWAL — 20 produk poster SUKA TEA, 22 Nov 2026 (disetujui Sendy).
/// Harga poster = Reguler. Jumbo = Reguler + Rp2.000 (pola seed lama:
/// 3K→5K, 5K→7K, 6K→8K, 8K→10K). Foto default = crop poster di
/// assets/products/ — Owner tetap bisa ubah nama, kategori, harga, dan
/// foto tiap produk di Kelola Menu (lokal dulu, sinkron Supabase di M1).
/// Seed ini dipakai supaya layar Kasir bisa dites sebelum proyek Supabase
/// + data outlet dibuat, dan jadi isi awal saat outlet dibuat.
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

/// Kategori menu poster — dipakai filter Kasir + dropdown Kelola Menu.
const List<String> menuCategories = [
  'Best Seller',
  'Milktea',
  'Mixtea',
];

/// Semua foto produk bawaan (crop poster, 600x600). Owner bisa pilih
/// salah satunya sebagai foto produk di Kelola Menu.
const List<String> bundledProductPhotos = [
  'assets/products/01-manggo-milktea.jpg',
  'assets/products/02-coklat-milktea.jpg',
  'assets/products/03-red-velvet-milktea.jpg',
  'assets/products/04-taro-milktea.jpg',
  'assets/products/05-thai-tea.jpg',
  'assets/products/06-es-teh-jumbo.jpg',
  'assets/products/07-es-teh-susu.jpg',
  'assets/products/08-es-teh-lemon.jpg',
  'assets/products/09-es-teh-yakult.jpg',
  'assets/products/10-es-teh-apel.jpg',
  'assets/products/11-es-teh-coklat.jpg',
  'assets/products/12-es-teh-alpukat.jpg',
  'assets/products/13-es-teh-caffe-latte.jpg',
  'assets/products/14-es-teh-taro.jpg',
  'assets/products/15-es-teh-leci.jpg',
  'assets/products/16-es-teh-vanilla-latte.jpg',
  'assets/products/17-es-teh-durian.jpg',
  'assets/products/18-es-teh-strawberry.jpg',
  'assets/products/19-es-teh-permen-karet.jpg',
  'assets/products/20-es-teh-green-tea.jpg',
];

List<Product> seedMenu() {
  Product p(String id, String name, String cat, int reg, String photo) =>
      Product(
        id: id,
        name: name,
        category: cat,
        photoUrl: photo,
        variants: [
          ProductVariant(id: '${id}_r', name: 'Reguler', sizeOz: 16, price: reg),
          ProductVariant(
            id: '${id}_j',
            name: 'Jumbo',
            sizeOz: 22,
            price: reg + 2000,
          ),
        ],
      );

  return [
    // VARIAN MILKTEA — 8K
    p('manggo-milktea', 'Manggo Milktea', 'Milktea', 8000,
        'assets/products/01-manggo-milktea.jpg'),
    p('coklat-milktea', 'Coklat Milktea', 'Milktea', 8000,
        'assets/products/02-coklat-milktea.jpg'),
    p('red-velvet-milktea', 'Red Velvet Milktea', 'Milktea', 8000,
        'assets/products/03-red-velvet-milktea.jpg'),
    p('taro-milktea', 'Taro Milktea', 'Milktea', 8000,
        'assets/products/04-taro-milktea.jpg'),
    p('thai-tea', 'Thai Tea', 'Milktea', 8000,
        'assets/products/05-thai-tea.jpg'),
    // BEST SELLER
    p('es-teh-jumbo', 'Es Teh Jumbo', 'Best Seller', 3000,
        'assets/products/06-es-teh-jumbo.jpg'),
    p('es-teh-susu', 'Es Teh Susu', 'Best Seller', 5000,
        'assets/products/07-es-teh-susu.jpg'),
    p('es-teh-lemon', 'Es Teh Lemon', 'Best Seller', 5000,
        'assets/products/08-es-teh-lemon.jpg'),
    p('es-teh-yakult', 'Es Teh Yakult', 'Best Seller', 7000,
        'assets/products/09-es-teh-yakult.jpg'),
    p('es-teh-apel', 'Es Teh Apel', 'Best Seller', 6000,
        'assets/products/10-es-teh-apel.jpg'),
    // VARIAN MIXTEA — 6K
    p('es-teh-coklat', 'Es Teh Coklat', 'Mixtea', 6000,
        'assets/products/11-es-teh-coklat.jpg'),
    p('es-teh-alpukat', 'Es Teh Alpukat', 'Mixtea', 6000,
        'assets/products/12-es-teh-alpukat.jpg'),
    p('es-teh-caffe-latte', 'Es Teh Caffe Latte', 'Mixtea', 6000,
        'assets/products/13-es-teh-caffe-latte.jpg'),
    p('es-teh-taro', 'Es Teh Taro', 'Mixtea', 6000,
        'assets/products/14-es-teh-taro.jpg'),
    p('es-teh-leci', 'Es Teh Leci', 'Mixtea', 6000,
        'assets/products/15-es-teh-leci.jpg'),
    p('es-teh-vanilla-latte', 'Es Teh Vanilla Latte', 'Mixtea', 6000,
        'assets/products/16-es-teh-vanilla-latte.jpg'),
    p('es-teh-durian', 'Es Teh Durian', 'Mixtea', 6000,
        'assets/products/17-es-teh-durian.jpg'),
    p('es-teh-strawberry', 'Es Teh Strawberry', 'Mixtea', 6000,
        'assets/products/18-es-teh-strawberry.jpg'),
    p('es-teh-permen-karet', 'Es Teh Permen Karet', 'Mixtea', 6000,
        'assets/products/19-es-teh-permen-karet.jpg'),
    p('es-teh-green-tea', 'Es Teh Green Tea', 'Mixtea', 6000,
        'assets/products/20-es-teh-green-tea.jpg'),
  ];
}

List<StockItem> seedStock() => const [
      StockItem(name: 'Teh', unit: 'kg', qty: 2.5, lowThreshold: 1),
      StockItem(name: 'Gula', unit: 'kg', qty: 5, lowThreshold: 2),
      StockItem(name: 'Cup 16oz', unit: 'pcs', qty: 120, lowThreshold: 50),
      StockItem(name: 'Cup 22oz', unit: 'pcs', qty: 80, lowThreshold: 50),
      StockItem(name: 'Es batu', unit: 'kg', qty: 10, lowThreshold: 5),
      StockItem(name: 'Sedotan', unit: 'pcs', qty: 200, lowThreshold: 100),
      // Bahan resep (22 Nov 2026): dipakai seedRecipes(). Jangan ubah
      // 6 bahan di atas — angka awalnya sudah disetujui.
      StockItem(name: 'Susu bubuk', unit: 'kg', qty: 3, lowThreshold: 1),
      StockItem(name: 'Bubuk perasa', unit: 'kg', qty: 2, lowThreshold: 0.5),
      StockItem(name: 'Yakult', unit: 'pcs', qty: 24, lowThreshold: 12),
      StockItem(name: 'Lemon', unit: 'pcs', qty: 20, lowThreshold: 10),
      // Topping (Batch C1): 1 porsi per topping per cup. Satuan
      // "porsi", stok awal 50 (pola bahan pcs: Lemon 20, Yakult 24 —
      // topping dipakai di hampir tiap cup, jadi stok awal lebih besar).
      StockItem(name: 'Boba', unit: 'porsi', qty: 50, lowThreshold: 10),
      StockItem(name: 'Jelly', unit: 'porsi', qty: 50, lowThreshold: 10),
      StockItem(name: 'Selasih', unit: 'porsi', qty: 50, lowThreshold: 10),
    ];

/// Estimasi biaya bahan per satuan (rupiah) — HANYA untuk HPP estimasi
/// di Keuangan/Laporan. Angka perkiraan pasar 2026, BUKAN harga beli
/// aktual; UI wajib menulis "estimasi". Bahan yang tidak ada di peta
/// ini dihitung Rp0.
const Map<String, double> seedStockCostPerUnit = {
  'Teh': 120000,
  'Gula': 18000,
  'Cup 16oz': 500,
  'Cup 22oz': 600,
  'Es batu': 5000,
  'Sedotan': 100,
  'Susu bubuk': 60000,
  'Bubuk perasa': 80000,
  'Yakult': 3500,
  'Lemon': 2000,
  // Topping (Batch C1): biaya awal 0 — harga bahan DITENTUKAN Owner
  // di halaman Stok (belum ada editor biaya di app; HPP topping
  // tetap 0 sampai fitur itu dibangun — JANGAN isi estimasi sendiri).
  'Boba': 0,
  'Jelly': 0,
  'Selasih': 0,
};
