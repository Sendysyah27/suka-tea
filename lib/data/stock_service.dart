import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'models.dart';
import 'recipe_logic.dart';
import 'seed_menu.dart';
import 'seed_recipes.dart';

/// Stok bahan + resep, di memori (ChangeNotifier) dan dicerminkan ke Drift.
/// Semua tulis ke DB dibungkus try/catch (pola OutboxService): gagal
/// simpan tidak boleh crash app — state memori tetap yang dipakai kasir.
class StockService extends ChangeNotifier {
  StockService._();

  static final StockService instance = StockService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<StockItem> _levels = [];
  Map<String, List<RecipeLine>> _recipes = {};
  bool _initialized = false;

  /// Daftar stok saat ini (salinan — ubah lewat updateStock/addStockItem).
  List<StockItem> get levels => List.unmodifiable(_levels);

  /// Semua resep per variant id (salinan — ubah lewat setRecipe).
  Map<String, List<RecipeLine>> get recipes => Map.unmodifiable(_recipes);

  bool get isInitialized => _initialized;

  Map<String, StockItem> get stockByName =>
      {for (final s in _levels) s.name: s};

  List<RecipeLine> recipesFor(String variantId) =>
      List.unmodifiable(_recipes[variantId] ?? const <RecipeLine>[]);

  /// Baca Drift; kalau tabel stok kosong, seed dari seedStock() +
  /// seedRecipes() lalu simpan. Dipanggil di main() sebelum runApp.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final dbLevels = await _database.select(_database.stockLevels).get();
      if (dbLevels.isEmpty) {
        _levels = seedStock();
        _recipes = seedRecipes();
        await _saveAllLevels();
        await _saveAllRecipes();
      } else {
        _levels = dbLevels
            .map((r) => StockItem(
                  name: r.name,
                  unit: r.unit,
                  qty: r.qty,
                  lowThreshold: r.lowThreshold,
                ))
            .toList();
        final dbRecipes =
            await _database.select(_database.productRecipes).get();
        final map = <String, List<RecipeLine>>{};
        for (final r in dbRecipes) {
          (map[r.variantId] ??= [])
              .add(RecipeLine(stockName: r.stockName, qty: r.qty));
        }
        // Resep kosong (mis. upgrade dari v1 yang tabel resepnya sempat
        // gagal dibuat) -> seed ulang resepnya saja.
        if (map.isEmpty) {
          _recipes = seedRecipes();
          await _saveAllRecipes();
        } else {
          _recipes = map;
        }
      }
    } catch (e) {
      // DB rusak / belum siap: kasir tetap jalan dengan seed di memori.
      debugPrint('StockService init gagal, pakai seed di memori: $e');
      if (_levels.isEmpty) _levels = seedStock();
      if (_recipes.isEmpty) _recipes = seedRecipes();
    }
    _initialized = true;
    notifyListeners();
  }

  /// Ganti satu resep varian (dipakai editor Resep). [lines] disalin.
  Future<void> setRecipe(String variantId, List<RecipeLine> lines) async {
    final clean = lines.where((l) => l.qty > 0).toList();
    _recipes[variantId] = List.unmodifiable(clean);
    notifyListeners();
    try {
      await (_database.delete(_database.productRecipes)
            ..where((t) => t.variantId.equals(variantId)))
          .go();
      for (final line in clean) {
        await _database.into(_database.productRecipes).insert(
              ProductRecipesCompanion.insert(
                variantId: variantId,
                stockName: line.stockName,
                qty: line.qty,
              ),
            );
      }
    } catch (e) {
      debugPrint('StockService setRecipe gagal simpan: $e');
    }
  }

  /// Ubah jumlah + ambang satu bahan.
  Future<void> updateStock(
    String name,
    double qty,
    double lowThreshold,
  ) async {
    final i = _levels.indexWhere((s) => s.name == name);
    if (i < 0) return;
    _levels[i] = StockItem(
      name: name,
      unit: _levels[i].unit,
      qty: qty,
      lowThreshold: lowThreshold,
    );
    notifyListeners();
    await _saveOneLevel(_levels[i]);
  }

  /// Tambah bahan baru. false = nama sudah ada (Owner harus edit yang ada).
  Future<bool> addStockItem(
    String name,
    String unit,
    double qty,
    double lowThreshold,
  ) async {
    if (_levels.any((s) => s.name == name)) return false;
    final item = StockItem(
      name: name,
      unit: unit,
      qty: qty,
      lowThreshold: lowThreshold,
    );
    _levels = [..._levels, item];
    notifyListeners();
    await _saveOneLevel(item);
    return true;
  }

  /// Jumlah varian yang resepnya memakai bahan ini (untuk label
  /// "Dipakai di: N varian" di tab Stok).
  int usageCount(String stockName) {
    var n = 0;
    for (final lines in _recipes.values) {
      if (lines.any((l) => l.stockName == stockName)) n++;
    }
    return n;
  }

  /// Bahan yang kurang untuk keranjang saat ini (resep + stok saat ini).
  List<Shortage> checkCart(List<CartItem> cart) =>
      findShortages(cart, _recipes, stockByName);

  /// Potong stok sesuai resep keranjang yang baru dibayar.
  /// Stok di-clamp di 0 (tidak pernah negatif). Mengembalikan nama bahan
  /// yang SEBELUM potong masih aman tapi SESUDAH potong jadi menipis —
  /// untuk SnackBar peringatan di Kasir. Mutasi juga dicatat ke outbox
  /// (kind 'stock_movement') supaya bisa disinkronkan di M1; gagal
  /// catat tidak menggagalkan penjualan.
  Future<List<String>> deductForSale(List<CartItem> cart) async {
    final deductions = computeDeductions(cart, _recipes, stockByName);
    if (deductions.isEmpty) return const [];
    final newlyLow = <String>[];
    for (final entry in deductions.entries) {
      final i = _levels.indexWhere((s) => s.name == entry.key);
      if (i < 0) continue;
      final before = _levels[i];
      final afterQty = (before.qty - entry.value).clamp(0.0, double.infinity);
      final wasLow = before.isLow;
      _levels[i] = StockItem(
        name: before.name,
        unit: before.unit,
        qty: afterQty,
        lowThreshold: before.lowThreshold,
      );
      if (!wasLow && _levels[i].isLow) newlyLow.add(before.name);
    }
    notifyListeners();
    await _saveAllLevels();
    try {
      await OutboxService.instance.enqueueSale(
        {
          'client_uuid': DateTime.now().microsecondsSinceEpoch.toString(),
          'reason': 'penjualan',
          'deductions': deductions,
        },
        kind: 'stock_movement',
      );
    } catch (e) {
      debugPrint('StockService outbox mutasi gagal (penjualan tetap sah): $e');
    }
    return newlyLow;
  }

  Future<void> _saveOneLevel(StockItem item) async {
    try {
      await _database.into(_database.stockLevels).insert(
            StockLevelsCompanion.insert(
              name: item.name,
              unit: item.unit,
              qty: item.qty,
              lowThreshold: item.lowThreshold,
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('StockService simpan stok gagal: $e');
    }
  }

  Future<void> _saveAllLevels() async {
    try {
      for (final item in _levels) {
        await _database.into(_database.stockLevels).insert(
              StockLevelsCompanion.insert(
                name: item.name,
                unit: item.unit,
                qty: item.qty,
                lowThreshold: item.lowThreshold,
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
    } catch (e) {
      debugPrint('StockService simpan semua stok gagal: $e');
    }
  }

  Future<void> _saveAllRecipes() async {
    try {
      for (final entry in _recipes.entries) {
        for (final line in entry.value) {
          await _database.into(_database.productRecipes).insert(
                ProductRecipesCompanion.insert(
                  variantId: entry.key,
                  stockName: line.stockName,
                  qty: line.qty,
                ),
                mode: InsertMode.insertOrReplace,
              );
        }
      }
    } catch (e) {
      debugPrint('StockService simpan semua resep gagal: $e');
    }
  }
}
