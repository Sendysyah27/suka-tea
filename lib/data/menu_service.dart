import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'models.dart';
import 'seed_menu.dart';

/// SATU sumber menu untuk Kasir + Kelola Menu (perbaiki bug #22:
/// dulu Kasir dan Katalog masing-masing seedMenu() sendiri, jadi edit
/// Katalog tidak tampil di Kasir dan hilang saat restart).
///
/// Sumber kebenaran lokal = tabel LocalProducts (Drift). Kalau tabel
/// masih kosong (install pertama / upgrade dari versi lama), seed dari
/// seedMenu() lalu simpan ke LocalProducts. Produk seed vs LocalProducts:
/// LocalProducts MENANG — sekali tersimpan, seed tidak pernah
/// menimpa editan Owner. Produk seed baru (bila suatu hari seed
/// bertambah) tidak otomatis muncul; Owner menambahkannya lewat
/// Kelola Menu.
///
/// Semua tulis ke DB dibungkus try/catch (pola StockService): gagal
/// simpan tidak boleh crash app — state memori tetap yang dipakai.
///
/// Widget test yang memompa KasirPage tanpa main() tetap jalan:
/// bila belum init, [products] mengembalikan seedMenu() sinkron.
class MenuService extends ChangeNotifier {
  MenuService._();

  static final MenuService instance = MenuService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<Product> _products = [];
  bool _initialized = false;

  /// Daftar produk saat ini (salinan — ubah lewat method di bawah).
  /// Sebelum init: seed sinkron supaya widget test tetap jalan.
  List<Product> get products =>
      _initialized ? List.unmodifiable(_products) : seedMenu();

  bool get isInitialized => _initialized;

  Product? byId(String id) {
    for (final p in products) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Baca Drift; kalau tabel kosong, seed lalu simpan.
  /// Dipanggil di main() sebelum runApp.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.localProducts).get();
      if (rows.isEmpty) {
        _products = seedMenu();
        await _saveAll();
      } else {
        _products = rows
            .map(
              (r) => Product(
                id: r.id,
                name: r.name,
                category: r.category,
                photoUrl: r.photoUrl,
                isActive: r.isActive,
                variants: [
                  ProductVariant(
                    id: '${r.id}_r',
                    name: 'Reguler',
                    sizeOz: 16,
                    price: r.priceReguler,
                  ),
                  ProductVariant(
                    id: '${r.id}_j',
                    name: 'Jumbo',
                    sizeOz: 22,
                    price: r.priceJumbo,
                  ),
                ],
              ),
            )
            .toList();
      }
    } catch (e) {
      // DB rusak / belum siap: kasir tetap jalan dengan seed di memori.
      debugPrint('MenuService init gagal, pakai seed di memori: $e');
      if (_products.isEmpty) _products = seedMenu();
    }
    _initialized = true;
    notifyListeners();
  }

  /// Simpan / perbarui satu produk (edit nama/kategori/harga/foto).
  Future<void> updateProduct(Product product) async {
    final i = _products.indexWhere((p) => p.id == product.id);
    if (i < 0) return;
    _products[i] = product;
    notifyListeners();
    await _saveOne(product);
  }

  /// Tambah produk baru (id sudah ditentukan pemanggil).
  Future<void> addProduct(Product product) async {
    if (_products.any((p) => p.id == product.id)) return;
    _products = [..._products, product];
    notifyListeners();
    await _saveOne(product);
  }

  /// Hapus produk (dengan konfirmasi di UI pemanggil).
  Future<void> removeProduct(String id) async {
    _products = _products.where((p) => p.id != id).toList();
    notifyListeners();
    try {
      await (_database.delete(_database.localProducts)
            ..where((t) => t.id.equals(id)))
          .go();
    } catch (e) {
      debugPrint('MenuService hapus gagal simpan: $e');
    }
  }

  /// Toggle Aktif/Habis satu produk.
  Future<void> setActive(String id, bool active) async {
    final p = byId(id);
    if (p == null || p.isActive == active) return;
    await updateProduct(
      Product(
        id: p.id,
        name: p.name,
        category: p.category,
        photoUrl: p.photoUrl,
        variants: p.variants,
        isActive: active,
      ),
    );
  }

  Future<void> _saveOne(Product p) async {
    try {
      await _database.into(_database.localProducts).insert(
            LocalProductsCompanion.insert(
              id: p.id,
              name: p.name,
              category: p.category,
              priceReguler: p.variants.first.price,
              priceJumbo: p.variants.last.price,
              photoUrl: Value(p.photoUrl),
              isActive: p.isActive,
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('MenuService simpan produk gagal: $e');
    }
  }

  Future<void> _saveAll() async {
    for (final p in _products) {
      await _saveOne(p);
    }
  }
}
