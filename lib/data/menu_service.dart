import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'master_sync.dart';
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
                // Batch C8.2 WS7: SATU varian — 22oz, harga poster.
                // priceReguler di Drift = harga tunggal itu
                // (priceJumbo lama diabaikan — tidak lagi dibaca).
                variants: [
                  ProductVariant(
                    id: '${r.id}_22oz',
                    name: '22oz',
                    sizeOz: 22,
                    price: r.priceReguler,
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
  /// Batch C10 WS0: perubahan produk = master-data — antre event
  /// 'master' (entity product) supaya gerai/HP lain ikut berubah.
  Future<void> updateProduct(Product product) async {
    final i = _products.indexWhere((p) => p.id == product.id);
    if (i < 0) return;
    _products[i] = product;
    notifyListeners();
    await _saveOne(product);
    await _enqueueMasterProduct(product);
  }

  /// Tambah produk baru (id sudah ditentukan pemanggil).
  Future<void> addProduct(Product product) async {
    if (_products.any((p) => p.id == product.id)) return;
    _products = [..._products, product];
    notifyListeners();
    await _saveOne(product);
    await _enqueueMasterProduct(product);
  }

  /// Hapus produk (dengan konfirmasi di UI pemanggil).
  /// Batch C10 WS0: hapus = NONAKTIF + event is_deleted — produk
  /// tetap ada di Riwayat + void-restore bisa jalan; HP lain
  /// menyembunyikan dari Kasir (bukan hapus fisik dari history).
  Future<void> removeProduct(String id) async {
    final product = byId(id);
    if (product == null) return;
    _products = _products
        .map(
          (p) => p.id == id
              ? Product(
                  id: p.id,
                  name: p.name,
                  category: p.category,
                  photoUrl: p.photoUrl,
                  variants: p.variants,
                  isActive: false,
                )
              : p,
        )
        .toList();
    notifyListeners();
    await _saveOne(
      Product(
        id: product.id,
        name: product.name,
        category: product.category,
        photoUrl: product.photoUrl,
        variants: product.variants,
        isActive: false,
      ),
    );
    await _enqueueMaster(
      MasterChange(
        entity: MasterEntity.product,
        id: id,
        updatedAt: DateTime.now().toUtc(),
        isDeleted: true,
        data: _productData(
          product,
          isActive: false,
        ),
      ),
    );
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
      // Batch C8.2 WS7: harga tunggal = variants.first.price.
      // priceJumbo ditulis SAMA (kolom Drift dipertahankan supaya
      // skema tidak berubah — nilainya tidak lagi dibaca).
      final price = p.variants.first.price;
      await _database.into(_database.localProducts).insert(
            LocalProductsCompanion.insert(
              id: p.id,
              name: p.name,
              category: p.category,
              priceReguler: price,
              priceJumbo: price,
              photoUrl: Value(p.photoUrl),
              isActive: Value(p.isActive),
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

  // ===================== Master sync (Batch C10 WS0) =====================

  static Map<String, Object?> _productData(
    Product p, {
    bool? isActive,
  }) {
    final price = p.variants.isEmpty ? 0 : p.variants.first.price;
    return {
      'id': p.id,
      'name': p.name,
      'category': p.category,
      'price': price,
      'photo_url': p.photoUrl,
      'is_active': isActive ?? p.isActive,
    };
  }

  Future<void> _enqueueMaster(MasterChange change) async {
    try {
      await OutboxService.instance.enqueueSale(
        change.toEventPayload(),
        kind: 'master',
      );
    } catch (e) {
      debugPrint('MenuService antre master gagal: $e');
    }
  }

  Future<void> _enqueueMasterProduct(Product product) async {
    await _enqueueMaster(
      MasterChange(
        entity: MasterEntity.product,
        id: product.id,
        updatedAt: DateTime.now().toUtc(),
        data: _productData(product),
      ),
    );
  }

  /// Terapkan produk hasil pull server (Batch C10 WS0): perubahan
  /// yang menang LWW (bukan pending) diterapkan ke memori + Drift.
  /// Produk is_deleted = nonaktif (tetap di Riwayat, hilang dari
  /// Kasir). Produk BARU dari HP lain disisipkan.
  Future<void> mergePulledProducts(List<MasterChange> serverChanges) async {
    if (!_initialized) return;
    final pending = await OutboxService.instance.pendingMasterKeys();
    final localUpdatedAt = <String, DateTime>{};
    // LocalProducts tidak menyimpan updated_at — pakai epoch: server
    // menang bila ada perubahan; perubahan lokal yang belum terkirim
    // dilindungi pendingKeys (kunci 'product|<id>').
    for (final p in _products) {
      localUpdatedAt['${MasterEntity.product}|${p.id}'] =
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    final plan = planMasterMerge(
      serverChanges: serverChanges,
      localUpdatedAt: localUpdatedAt,
      pendingKeys: pending,
    );
    if (plan.isEmpty) return;
    var changed = false;
    for (final change in plan) {
      final name = change.data['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final price = (change.data['price'] as num? ?? 0).toInt();
      final category = change.data['category'] as String? ?? 'Mixtea';
      final photoUrl = change.data['photo_url'] as String?;
      final isActive = change.isDeleted
          ? false
          : (change.data['is_active'] as bool? ?? true);
      final product = Product(
        id: change.id,
        name: name,
        category: category,
        photoUrl: photoUrl,
        isActive: isActive,
        variants: [
          ProductVariant(
            id: '${change.id}_22oz',
            name: '22oz',
            sizeOz: 22,
            price: price,
          ),
        ],
      );
      final i = _products.indexWhere((p) => p.id == change.id);
      if (i < 0) {
        _products = [..._products, product];
      } else {
        _products = List<Product>.of(_products)..[i] = product;
      }
      changed = true;
      await _saveOne(product);
    }
    if (changed) notifyListeners();
  }
}
