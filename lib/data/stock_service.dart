import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'models.dart';
import 'outlet_service.dart';
import 'recipe_logic.dart';
import 'seed_menu.dart';
import 'seed_recipes.dart';
import 'sync_payload.dart';

/// Stok bahan + resep, di memori (ChangeNotifier) dan dicerminkan ke Drift.
/// Semua tulis ke DB dibungkus try/catch (pola OutboxService): gagal
/// simpan tidak boleh crash app — state memori tetap yang dipakai kasir.
///
/// Batch C8.2 WS5 — STOK PER GERAI: tiap gerai punya bahan baku
/// sendiri (Gerai 1 pakai teh tidak mengurangi Gerai 2). Level stok
/// disimpan per outlet ([_levelsByOutlet]); semua baca/tulis lewat
/// getter tanpa outlet memakai gerai AKTIF ([_activeOutletId]).
/// Resep TETAP global (menu-level, sama di semua gerai).
class StockService extends ChangeNotifier {
  StockService._();

  static final StockService instance = StockService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  /// Level stok per outlet — kunci = outletId.
  Map<String, List<StockItem>> _levelsByOutlet = {};
  Map<String, List<RecipeLine>> _recipes = {};
  bool _initialized = false;

  /// Gerai yang stoknya sedang dipakai (diikuti dari OutletService).
  String get _activeOutletId => OutletService.instance.currentOutletId;

  /// Level stok gerai aktif (salinan — ubah lewat updateStock /
  /// addStockItem). Dipakai tab Kasir + Stok + resep/deduct/restore.
  List<StockItem> get levels => levelsFor(_activeOutletId);

  /// Level stok satu gerai (salinan). Dipakai Pantau Gerai untuk
  /// gerai yang sedang dilihat (bisa beda dari gerai aktif).
  List<StockItem> levelsFor(String outletId) =>
      List.unmodifiable(_levelsByOutlet[outletId] ?? const <StockItem>[]);

  /// Semua resep per variant id (salinan — ubah lewat setRecipe).
  Map<String, List<RecipeLine>> get recipes => Map.unmodifiable(_recipes);

  bool get isInitialized => _initialized;

  /// Stok gerai aktif, kunci nama bahan.
  Map<String, StockItem> get stockByName => stockByNameFor(_activeOutletId);

  /// Stok satu gerai, kunci nama bahan.
  Map<String, StockItem> stockByNameFor(String outletId) =>
      {for (final s in levelsFor(outletId)) s.name: s};

  List<RecipeLine> recipesFor(String variantId) =>
      List.unmodifiable(_recipes[variantId] ?? const <RecipeLine>[]);

  /// Baca Drift; kalau tabel stok kosong, seed dari seedStock() +
  /// seedRecipes() lalu simpan. Dipanggil di main() sebelum runApp.
  /// Seed yang BARU (bahan yang belum ada di DB — mis. Boba/Jelly/
  /// Selasih dari Batch C1) ditambahkan tanpa menyentuh stok yang
  /// sudah ada: install lama yang sudah punya 10 bahan tetap
  /// mendapat 3 bahan topping saat upgrade, tanpa reset jumlah.
  /// Batch C8.2 WS5: seed per OUTLET — outlet yang pertama dipakai
  /// mendapat seed lengkap; outlet yang sudah ada datanya TIDAK
  /// di-seed ulang (lihat [ensureOutlet]).
  Future<void> init() async {
    if (_initialized) return;
    try {
      final dbLevels = await _database.select(_database.stockLevels).get();
      final byOutlet = <String, List<StockItem>>{};
      for (final r in dbLevels) {
        (byOutlet[r.outletId] ??= []).add(
          StockItem(
            name: r.name,
            unit: r.unit,
            qty: r.qty,
            lowThreshold: r.lowThreshold,
            costPerUnit: r.costPerUnit,
            outletId: r.outletId,
          ),
        );
      }
      _levelsByOutlet = byOutlet;
      // Gerai aktif selalu punya stok (seed bila pertama dipakai).
      await ensureOutlet(_activeOutletId);
      final dbRecipes =
          await _database.select(_database.productRecipes).get();
      final map = <String, List<RecipeLine>>{};
      for (final r in dbRecipes) {
        (map[r.variantId] ??= [])
            .add(RecipeLine(stockName: r.stockName, qty: r.qty));
      }
      // Resep kosong (mis. upgrade dari v1 yang tabel resepnya sempat
      // gagal dibuat) -> seed ulang resepnya saja.
      // Batch C8.2 WS7: resep seed yang belum ada di DB -> tambahkan
      // per variantId (install lama punya resep _r/_j tapi belum
      // punya _22oz — resep lama DIBIARKAN, resep baru ditambahkan
      // supaya deduksi stok varian 22oz jalan).
      var addedRecipe = false;
      for (final entry in seedRecipes().entries) {
        if (map.containsKey(entry.key)) continue;
        map[entry.key] = entry.value;
        addedRecipe = true;
      }
      _recipes = map;
      if (addedRecipe) await _saveAllRecipes();
    } catch (e) {
      // DB rusak / belum siap: kasir tetap jalan dengan seed di memori.
      debugPrint('StockService init gagal, pakai seed di memori: $e');
      if (_levelsByOutlet[_activeOutletId]?.isEmpty ?? true) {
        _levelsByOutlet[_activeOutletId] =
            seedStock().map((s) => s.copyWith(outletId: _activeOutletId)).toList();
      }
      if (_recipes.isEmpty) _recipes = seedRecipes();
    }
    // Backfill biaya bahan (Batch C1b) untuk gerai aktif: bahan yang
    // biayanya masih -1 (belum diatur) dan seed punya nilai > 0
    // mendapat biaya seed sebagai default awal — install lama yang
    // upgrade ke schema v5 ikut dapat. Topping (seed 0) tetap -1
    // sampai Owner mengisinya di tab Stok; biaya yang Owner sudah
    // isi (>= 0, termasuk 0 = gratis) tidak disentuh.
    final active = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    final filled = backfillCosts(active, seedStockCostPerUnit);
    var backfilled = false;
    for (var i = 0; i < filled.length; i++) {
      if (filled[i].costPerUnit != active[i].costPerUnit) {
        backfilled = true;
      }
    }
    if (backfilled) {
      _levelsByOutlet[_activeOutletId] = filled;
      await _saveAllLevels();
    }
    _initialized = true;
    notifyListeners();
  }

  /// Pastikan [outletId] punya stok: bila belum ada baris sama sekali
  /// untuk gerai itu, seed lengkap (seedStock + backfill biaya) lalu
  /// simpan. Seed yang BARU (bahan yang belum ada di gerai itu —
  /// mis. Boba/Jelly/Selasih dari Batch C1) ditambahkan tanpa
  /// menyentuh stok yang sudah ada. Outlet yang sudah lengkap TIDAK
  /// disentuh. Dipanggil dari init (gerai aktif), login/restore,
  /// dan Pantau Gerai (gerai yang dilihat).
  Future<void> ensureOutlet(String outletId) async {
    final existing = _levelsByOutlet[outletId];
    var list = existing ?? const <StockItem>[];
    // Outlet belum dikenal = baru -> seed + simpan.
    var changed = existing == null;
    for (final seed in seedStock()) {
      if (list.any((s) => s.name == seed.name)) continue;
      list = [...list, seed.copyWith(outletId: outletId)];
      changed = true;
    }
    if (!changed) return;
    _levelsByOutlet[outletId] = backfillCosts(list, seedStockCostPerUnit);
    notifyListeners();
    await _saveAllLevels();
  }

  /// Peta biaya (nama bahan -> Rp per satuan) gerai aktif untuk HPP di
  /// Keuangan/Laporan. Sebelum init: kosong (HPP dihitung Rp0).
  Map<String, double> get costsByName => costsByNameFor(_activeOutletId);

  /// Peta biaya satu gerai (dipakai Pantau Gerai untuk gerai yang
  /// dilihat — HPP dihitung dari stok gerai itu).
  Map<String, double> costsByNameFor(String outletId) =>
      costsFromLevels(levelsFor(outletId));

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

  /// Ubah harga per satuan satu bahan gerai aktif (HANYA Owner —
  /// dicek di UI). false = bahan tidak ada atau biaya negatif.
  Future<bool> updateCost(String name, double cost) async {
    if (!isValidCost(cost)) return false;
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    final i = levels.indexWhere((s) => s.name == name);
    if (i < 0) return false;
    final updated = [...levels];
    updated[i] = updated[i].copyWith(costPerUnit: cost);
    _levelsByOutlet[_activeOutletId] = updated;
    notifyListeners();
    await _saveOneLevel(updated[i]);
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

  /// Ubah jumlah + ambang satu bahan gerai aktif. Harga per satuan
  /// ikut dipertahankan (copyWith) supaya tidak ke-reset ke 0.
  Future<void> updateStock(
    String name,
    double qty,
    double lowThreshold,
  ) async {
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    final i = levels.indexWhere((s) => s.name == name);
    if (i < 0) return;
    final updated = [...levels];
    updated[i] = updated[i].copyWith(qty: qty, lowThreshold: lowThreshold);
    _levelsByOutlet[_activeOutletId] = updated;
    notifyListeners();
    await _saveOneLevel(updated[i]);
  }

  /// Tambah bahan baru di gerai aktif. false = nama sudah ada di
  /// gerai itu (Owner harus edit yang ada).
  Future<bool> addStockItem(
    String name,
    String unit,
    double qty,
    double lowThreshold,
  ) async {
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    if (levels.any((s) => s.name == name)) return false;
    final item = StockItem(
      name: name,
      unit: unit,
      qty: qty,
      lowThreshold: lowThreshold,
      outletId: _activeOutletId,
    );
    _levelsByOutlet[_activeOutletId] = [...levels, item];
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

  /// Bahan yang kurang untuk keranjang saat ini (resep + stok gerai
  /// aktif saat ini).
  List<Shortage> checkCart(List<CartItem> cart) =>
      findShortages(cart, _recipes, stockByName);

  /// Potong stok gerai aktif sesuai resep keranjang yang baru dibayar.
  /// Stok di-clamp di 0 (tidak pernah negatif). Mengembalikan nama
  /// bahan yang SEBELUM potong masih aman tapi SESUDAH potong jadi
  /// menipis — untuk SnackBar peringatan di Kasir. Mutasi juga
  /// dicatat ke outbox (kind 'stock_movement') supaya bisa
  /// disinkronkan di M1; gagal catat tidak menggagalkan penjualan.
  /// Batch C6: payload mutasi membawa level lengkap per bahan
  /// (unit, qty_after, ambang, harga) + [transactionClientUuid]
  /// (client_uuid penjualan asal, bila ada) supaya server bisa
  /// menautkan mutasi ke transaksinya.
  /// Batch C8.2 WS5: outlet_id = gerai AKTIF (bukan lagi gerai utama
  /// — stok per gerai); server menerapkan DELTA, bukan qty_after.
  Future<List<String>> deductForSale(
    List<CartItem> cart, {
    String? transactionClientUuid,
  }) async {
    final deductions = computeDeductions(cart, _recipes, stockByName);
    if (deductions.isEmpty) return const [];
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    final updated = [...levels];
    final newlyLow = <String>[];
    final syncItems = <Map<String, dynamic>>[];
    for (final entry in deductions.entries) {
      final i = updated.indexWhere((s) => s.name == entry.key);
      if (i < 0) continue;
      final before = updated[i];
      final afterQty = (before.qty - entry.value).clamp(0.0, double.infinity);
      final wasLow = before.isLow;
      updated[i] = before.copyWith(qty: afterQty);
      if (!wasLow && updated[i].isLow) newlyLow.add(before.name);
      syncItems.add({
        'name': before.name,
        'unit': before.unit,
        'qty_after': afterQty,
        'low_threshold': before.lowThreshold,
        // -1 = harga belum diatur Owner -> server terima 0
        // (sama seperti HPP lokal yang menghitungnya Rp0).
        'cost_per_unit':
            before.costPerUnit < 0 ? 0 : before.costPerUnit.round(),
        'delta': -entry.value,
      });
    }
    _levelsByOutlet[_activeOutletId] = updated;
    notifyListeners();
    await _saveAllLevels();
    try {
      await OutboxService.instance.enqueueSale(
        {
          'client_uuid': newClientUuid(),
          'outlet_id': _activeOutletId,
          'reason': 'penjualan',
          if (transactionClientUuid != null)
            'transaction_client_uuid': transactionClientUuid,
          'items': syncItems,
        },
        kind: 'stock_movement',
      );
    } catch (e) {
      debugPrint('StockService outbox mutasi gagal (penjualan tetap sah): $e');
    }
    return newlyLow;
  }

  /// Kembalikan stok gerai aktif sesuai resep keranjang yang di-void
  /// (inverse dari deductForSale — JANGAN ubah deductForSale).
  /// Dipakai void di Riwayat. Stok hanya ditambah (tidak ada clamp
  /// atas); mutasi dicatat ke outbox (kind 'stock_movement',
  /// reason 'void'). Batch C6: payload sama lengkapnya dengan
  /// deductForSale. Batch C8.2 WS5: outlet_id = gerai AKTIF.
  Future<void> restoreForSale(
    List<CartItem> cart, {
    String? transactionClientUuid,
  }) async {
    final additions = computeDeductions(cart, _recipes, stockByName);
    if (additions.isEmpty) return;
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    final updated = [...levels];
    final syncItems = <Map<String, dynamic>>[];
    for (final entry in additions.entries) {
      final i = updated.indexWhere((s) => s.name == entry.key);
      if (i < 0) continue;
      final before = updated[i];
      updated[i] = before.copyWith(qty: before.qty + entry.value);
      syncItems.add({
        'name': before.name,
        'unit': before.unit,
        'qty_after': updated[i].qty,
        'low_threshold': before.lowThreshold,
        'cost_per_unit':
            before.costPerUnit < 0 ? 0 : before.costPerUnit.round(),
        'delta': entry.value,
      });
    }
    _levelsByOutlet[_activeOutletId] = updated;
    notifyListeners();
    await _saveAllLevels();
    try {
      await OutboxService.instance.enqueueSale(
        {
          'client_uuid': newClientUuid(),
          'outlet_id': _activeOutletId,
          'reason': 'void',
          if (transactionClientUuid != null)
            'transaction_client_uuid': transactionClientUuid,
          'items': syncItems,
        },
        kind: 'stock_movement',
      );
    } catch (e) {
      debugPrint('StockService outbox mutasi gagal (void tetap sah): $e');
    }
  }

  /// Ganti nama satu bahan di gerai aktif. false = nama baru sudah
  /// dipakai bahan lain di gerai itu (bentrok) atau nama lama tidak
  /// ada. Resep yang memakai bahan ini ikut diganti namanya supaya
  /// deduksi tetap jalan. (Resep global — ganti nama berlaku di
  /// semua gerai, karena resep dibagikan.)
  Future<bool> renameStock(String oldName, String newName) async {
    if (oldName == newName) return true;
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    if (levels.any((s) => s.name == newName)) return false;
    final i = levels.indexWhere((s) => s.name == oldName);
    if (i < 0) return false;
    final updated = [...levels];
    updated[i] = updated[i].copyWith(name: newName);
    _levelsByOutlet[_activeOutletId] = updated;
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
            ..where((t) =>
                t.outletId.equals(_activeOutletId) &
                t.name.equals(oldName)))
          .go();
      await _saveOneLevel(updated[i]);
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
              outletId: Value(
                item.outletId.isEmpty ? _activeOutletId : item.outletId,
              ),
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

  /// Simpan SEMUA level stok SEMUA gerai (insertOrReplace per baris).
  Future<void> _saveAllLevels() async {
    try {
      for (final levels in _levelsByOutlet.values) {
        for (final item in levels) {
          await _database.into(_database.stockLevels).insert(
                StockLevelsCompanion.insert(
                  outletId: Value(
                    item.outletId.isEmpty ? _activeOutletId : item.outletId,
                  ),
                  name: item.name,
                  unit: item.unit,
                  qty: item.qty,
                  lowThreshold: item.lowThreshold,
                  costPerUnit: Value(item.costPerUnit),
                ),
                mode: InsertMode.insertOrReplace,
              );
        }
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
