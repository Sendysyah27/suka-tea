import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'models.dart';
import 'seed_menu.dart';
import 'stock_service.dart';

/// Satu topping yang bisa dipilih di sheet opsi produk.
class ToppingItem {
  const ToppingItem({
    required this.id,
    required this.name,
    required this.priceDelta,
    this.active = true,
  });

  final String id;
  final String name;
  final int priceDelta; // tambahan harga per cup (rupiah)
  final bool active;

  ToppingItem copyWith({String? name, int? priceDelta, bool? active}) =>
      ToppingItem(
        id: id,
        name: name ?? this.name,
        priceDelta: priceDelta ?? this.priceDelta,
        active: active ?? this.active,
      );
}

/// Kelola topping — di memori (ChangeNotifier) dan dicerminkan ke
/// Drift (tabel Toppings). Sheet opsi produk membaca dari sini
/// (bukan lagi const seed_menu — toppingOptions di seed_menu hanya
/// jadi fallback bila tabel kosong / sebelum init).
///
/// Nama topping HARUS sama dengan nama bahan stok (Boba/Jelly/dll):
/// - topping baru -> bahan stok otomatis dibuat (satuan "porsi",
///   qty 0, cost 0 — Owner yang isi harga + stoknya di halaman Stok).
/// - topping diganti nama -> nama bahan stok ikut diganti (bila
///   tidak bentrok dengan bahan lain).
/// - topping dihapus -> bahan stoknya TETAP ADA (stoknya mungkin
///   masih ada, jangan dihapus diam-diam).
///
/// Semua tulis ke DB dibungkus try/catch (pola StockService): gagal
/// simpan tidak boleh crash app — state memori tetap yang dipakai.
///
/// Widget test yang memompa KasirPage tanpa main() tetap jalan:
/// bila belum init, [toppings] mengembalikan seed sinkron.
class ToppingService extends ChangeNotifier {
  ToppingService._();

  static final ToppingService instance = ToppingService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<ToppingItem> _toppings = [];
  bool _initialized = false;

  /// Daftar topping saat ini (salinan). Sebelum init: seed sinkron
  /// supaya widget test + sheet opsi tetap jalan.
  List<ToppingItem> get toppings =>
      _initialized ? List.unmodifiable(_toppings) : _seedToppings;

  bool get isInitialized => _initialized;

  /// Topping AKTIF sebagai Modifier (untuk sheet opsi produk).
  List<Modifier> get activeModifiers => toppings
      .where((t) => t.active)
      .map(
        (t) => Modifier(name: t.name, kind: 'topping', priceDelta: t.priceDelta),
      )
      .toList();

  /// Semua nama topping (aktif + nonaktif) — dipakai void untuk
  /// mengenali modifier topping dari nama saja (SaleItem hanya
  /// menyimpan nama modifier).
  Set<String> get toppingNames => toppings.map((t) => t.name).toSet();

  static List<ToppingItem> get _seedToppings => toppingOptions
      .map(
        (m) => ToppingItem(
          id: 'seed-${m.name.toLowerCase()}',
          name: m.name,
          priceDelta: m.priceDelta,
        ),
      )
      .toList();

  /// Baca Drift; kalau tabel kosong, seed dari toppingOptions lalu
  /// simpan. Dipanggil di main() sesudah StockService (stok harus
  /// siap dulu untuk sinkronisasi topping -> bahan stok).
  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.toppings).get();
      if (rows.isEmpty) {
        _toppings = _seedToppings;
        await _saveAll();
      } else {
        _toppings = rows
            .map(
              (r) => ToppingItem(
                id: r.id,
                name: r.name,
                priceDelta: r.priceDelta,
                active: r.active,
              ),
            )
            .toList();
      }
      // Pastikan tiap topping punya bahan stok (install lama / topping
      // yang dibuat sebelum sinkronisasi ada — jangan sampai topping
      // tidak pernah memotong stok karena bahannya hilang).
      for (final t in _toppings) {
        if (!StockService.instance.stockByName.containsKey(t.name)) {
          await StockService.instance.addStockItem(t.name, 'porsi', 0, 0);
        }
      }
    } catch (e) {
      // DB rusak / belum siap: sheet tetap jalan dengan seed di memori.
      debugPrint('ToppingService init gagal, pakai seed di memori: $e');
      if (_toppings.isEmpty) _toppings = _seedToppings;
    }
    _initialized = true;
    notifyListeners();
  }

  /// Tambah topping baru. false = nama kosong / harga negatif /
  /// nama sudah dipakai topping lain. Bahan stok otomatis dibuat.
  Future<bool> addTopping(String name, int priceDelta) async {
    final clean = name.trim();
    if (clean.isEmpty || priceDelta < 0) return false;
    if (_toppings.any(
      (t) => t.name.toLowerCase() == clean.toLowerCase(),
    )) {
      return false;
    }
    final item = ToppingItem(
      id: 'topping-${DateTime.now().microsecondsSinceEpoch}',
      name: clean,
      priceDelta: priceDelta,
    );
    _toppings = [..._toppings, item];
    notifyListeners();
    try {
      await _database.into(_database.toppings).insert(
            ToppingsCompanion.insert(
              id: item.id,
              name: item.name,
              priceDelta: item.priceDelta,
              active: const Value(true),
            ),
          );
    } catch (e) {
      debugPrint('ToppingService tambah gagal simpan: $e');
    }
    // Bahan stok otomatis (satuan porsi, qty 0 — Owner isi di Stok).
    // Bila bahan bernama sama sudah ada, addStockItem mengembalikan
    // false dan topping tetap dibuat (tidak digagalkan).
    await StockService.instance.addStockItem(clean, 'porsi', 0, 0);
    return true;
  }

  /// Ubah nama / harga topping. false = id tidak ada, nama kosong /
  /// harga negatif, nama bentrok dengan topping lain, atau nama bahan
  /// stok bentrok dengan bahan lain. Nama bahan stok ikut diganti.
  Future<bool> updateTopping(
    String id, {
    required String name,
    required int priceDelta,
  }) async {
    final i = _toppings.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    final clean = name.trim();
    if (clean.isEmpty || priceDelta < 0) return false;
    if (_toppings.any(
      (t) => t.id != id && t.name.toLowerCase() == clean.toLowerCase(),
    )) {
      return false;
    }
    final old = _toppings[i];
    if (clean != old.name) {
      // Ganti nama bahan stok juga — bila bahan lama memang ada.
      // Bila bahan lama tidak ada (mis. dibuat sebelum sinkronisasi),
      // buatkan bahan baru dengan nama baru.
      if (StockService.instance.stockByName.containsKey(old.name)) {
        final renamed =
            await StockService.instance.renameStock(old.name, clean);
        if (!renamed) return false;
      } else {
        await StockService.instance.addStockItem(clean, 'porsi', 0, 0);
      }
    }
    _toppings[i] = old.copyWith(name: clean, priceDelta: priceDelta);
    notifyListeners();
    try {
      await (_database.update(_database.toppings)
            ..where((t) => t.id.equals(id)))
          .write(
            ToppingsCompanion(
              name: Value(clean),
              priceDelta: Value(priceDelta),
            ),
          );
    } catch (e) {
      debugPrint('ToppingService ubah gagal simpan: $e');
    }
    return true;
  }

  /// Toggle aktif/nonaktif satu topping.
  Future<void> setActive(String id, bool active) async {
    final i = _toppings.indexWhere((t) => t.id == id);
    if (i < 0 || _toppings[i].active == active) return;
    _toppings[i] = _toppings[i].copyWith(active: active);
    notifyListeners();
    try {
      await (_database.update(_database.toppings)
            ..where((t) => t.id.equals(id)))
          .write(ToppingsCompanion(active: Value(active)));
    } catch (e) {
      debugPrint('ToppingService toggle gagal simpan: $e');
    }
  }

  /// Hapus topping (dengan konfirmasi di UI pemanggil).
  /// Bahan stoknya TETAP ADA — stoknya mungkin masih ada.
  Future<void> removeTopping(String id) async {
    _toppings = _toppings.where((t) => t.id != id).toList();
    notifyListeners();
    try {
      await (_database.delete(_database.toppings)
            ..where((t) => t.id.equals(id)))
          .go();
    } catch (e) {
      debugPrint('ToppingService hapus gagal simpan: $e');
    }
  }

  Future<void> _saveAll() async {
    for (final t in _toppings) {
      try {
        await _database.into(_database.toppings).insert(
              ToppingsCompanion.insert(
                id: t.id,
                name: t.name,
                priceDelta: t.priceDelta,
                active: Value(t.active),
              ),
            );
      } catch (e) {
        debugPrint('ToppingService seed gagal simpan: $e');
      }
    }
  }
}
