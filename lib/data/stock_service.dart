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
  /// Seed yang BARU (bahan yang belum ada di DB — mis. Boba/Jelly/
  /// Selasih dari Batch C1) ditambahkan tanpa menyentuh stok yang
  /// sudah ada: install lama yang sudah punya 10 bahan tetap
  /// mendapat 3 bahan topping saat upgrade, tanpa reset jumlah.
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
                  costPerUnit: r.costPerUnit,
                ))
            .toList();
        // Seed baru yang belum ada di DB -> tambahkan (jangan timpa).
        var addedSeed = false;
        for (final seed in seedStock()) {
          if (_levels.any((s) => s.name == seed.name)) continue;
          _levels = [..._levels, seed];
          addedSeed = true;
        }
        if (addedSeed) await _saveAllLevels();
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
    // Backfill biaya bahan (Batch C1b): bahan yang biayanya masih -1
    // (belum diatur) dan seed punya nilai > 0 mendapat biaya seed
    // sebagai default awal — install lama yang upgrade ke schema v5
    // ikut dapat. Topping (seed 0) tetap -1 sampai Owner mengisinya
    // di tab Stok; biaya yang Owner sudah isi (>= 0, termasuk 0 =
    // gratis) tidak disentuh.
    final filled = backfillCosts(_levels, seedStockCostPerUnit);
    var backfilled = false;
    for (var i = 0; i < filled.length; i++) {
      if (filled[i].costPerUnit != _levels[i].costPerUnit) {
        backfilled = true;
      }
    }
    _levels = filled;
    if (backfilled) await _saveAllLevels();
    _initialized = true;
    notifyListeners();
  }

  /// Peta biaya (nama bahan -> Rp per satuan) untuk HPP di
  /// Keuangan/Laporan. Sebelum init: kosong (HPP dihitung Rp0).
  Map<String, double> get costsByName => costsFromLevels(_levels);

  /// Peta biaya murni dari daftar level (dipakai costsByName + test).
  /// -1 (belum diatur) dihitung Rp0 untuk HPP — biaya tidak boleh
  /// negatif di perhitungan.
  static Map<String, double> costsFromLevels(List<StockItem> levels) =>
      {for (final s in levels) s.name: (s.costPerUnit < 0 ? 0.0 : s.costPerUnit)};

  /// true = biaya sah (>= 0). Negatif ditolak — biaya tidak boleh minus.
  static bool isValidCost(double cost) => cost >= 0;

  /// Backfill biaya awal dari [seedCosts]: tiap bahan yang biayanya
  /// masih -1 (belum diatur) dan seed punya nilai > 0 mendapat biaya
  /// seed. Bahan yang Owner sudah isi (>= 0 — termasuk 0 = gratis),
  /// bahan tanpa seed, dan topping (seed 0) tidak disentuh.
  /// Daftar asli tidak diubah (daftar baru dikembalikan).
  static List<StockItem> backfillCosts(
    List<StockItem> levels,
    Map<String, double> seedCosts,
  ) =>
      levels.map((s) {
        if (s.costPerUnit >= 0) return s;
        final seed = seedCosts[s.name];
        if (seed == null || seed <= 0) return s;
        return s.copyWith(costPerUnit: seed);
      }).toList();

  /// Ubah harga per satuan satu bahan (HANYA Owner — dicek di UI).
  /// false = bahan tidak ada atau biaya negatif.
  Future<bool> updateCost(String name, double cost) async {
    if (!isValidCost(cost)) return false;
    final i = _levels.indexWhere((s) => s.name == name);
    if (i < 0) return false;
    _levels[i] = _levels[i].copyWith(costPerUnit: cost);
    notifyListeners();
    await _saveOneLevel(_levels[i]);
    return true;
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

  /// Ubah jumlah + ambang satu bahan. Harga per satuan ikut
  /// dipertahankan (copyWith) supaya tidak ke-reset ke 0.
  Future<void> updateStock(
    String name,
    double qty,
    double lowThreshold,
  ) async {
    final i = _levels.indexWhere((s) => s.name == name);
    if (i < 0) return;
    _levels[i] = _levels[i].copyWith(qty: qty, lowThreshold: lowThreshold);
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
      _levels[i] = before.copyWith(qty: afterQty);
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

  /// Kembalikan stok sesuai resep keranjang yang di-void (inverse
  /// dari deductForSale — JANGAN ubah deductForSale). Dipakai void
  /// di Riwayat. Stok hanya ditambah (tidak ada clamp atas); mutasi
  /// dicatat ke outbox (kind 'stock_movement', reason 'void').
  Future<void> restoreForSale(List<CartItem> cart) async {
    final additions = computeDeductions(cart, _recipes, stockByName);
    if (additions.isEmpty) return;
    for (final entry in additions.entries) {
      final i = _levels.indexWhere((s) => s.name == entry.key);
      if (i < 0) continue;
      final before = _levels[i];
      _levels[i] = before.copyWith(qty: before.qty + entry.value);
    }
    notifyListeners();
    await _saveAllLevels();
    try {
      await OutboxService.instance.enqueueSale(
        {
          'client_uuid': DateTime.now().microsecondsSinceEpoch.toString(),
          'reason': 'void',
          'additions': additions,
        },
        kind: 'stock_movement',
      );
    } catch (e) {
      debugPrint('StockService outbox mutasi gagal (void tetap sah): $e');
    }
  }

  /// Ganti nama satu bahan. false = nama baru sudah dipakai bahan lain
  /// (bentrok) atau nama lama tidak ada. Resep yang memakai bahan ini
  /// ikut diganti namanya supaya deduksi tetap jalan.
  Future<bool> renameStock(String oldName, String newName) async {
    if (oldName == newName) return true;
    if (_levels.any((s) => s.name == newName)) return false;
    final i = _levels.indexWhere((s) => s.name == oldName);
    if (i < 0) return false;
    final before = _levels[i];
    _levels[i] = before.copyWith(name: newName);
    // Resep memakai nama bahan sebagai kunci — ganti juga di memori.
    final newRecipes = <String, List<RecipeLine>>{};
    for (final entry in _recipes.entries) {
      newRecipes[entry.key] = entry.value
          .map(
            (l) => l.stockName == oldName
                ? RecipeLine(stockName: newName, qty: l.qty)
                : l,
          )
          .toList();
    }
    _recipes = newRecipes;
    notifyListeners();
    try {
      await (_database.delete(_database.stockLevels)
            ..where((t) => t.name.equals(oldName)))
          .go();
      await _saveOneLevel(_levels[i]);
      await (_database.update(_database.productRecipes)
            ..where((t) => t.stockName.equals(oldName)))
          .write(
            ProductRecipesCompanion(stockName: Value(newName)),
          );
    } catch (e) {
      debugPrint('StockService rename gagal simpan: $e');
    }
    return true;
  }

  Future<void> _saveOneLevel(StockItem item) async {
    try {
      await _database.into(_database.stockLevels).insert(
            StockLevelsCompanion.insert(
              name: item.name,
              unit: item.unit,
              qty: item.qty,
              lowThreshold: item.lowThreshold,
              costPerUnit: Value(item.costPerUnit),
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
                costPerUnit: Value(item.costPerUnit),
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
