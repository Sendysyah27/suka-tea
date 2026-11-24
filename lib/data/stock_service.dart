import 'dart:convert';

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

/// Hasil rencana merge stok: yang harus disisipkan + yang harus
/// diperbarui (level lokal sudah ada, meta dari server). Dipakai
/// [StockService.mergePulledStock].
typedef StockMergePlan = ({
  List<StockItem> toInsert,
  List<StockItem> toUpdate,
});

/// Kunci "pernah disentuh device ini" = "$outletId|$name".
String stockTouchedKey(String outletId, String name) => '$outletId|$name';

/// Rencana merge stok server -> lokal (Batch C9, MURNI).
/// Aturan per item server:
/// - tidak ada level lokal -> sisipkan utuh (qty + meta server).
/// - level lokal ada TAPI belum pernah disentuh device ini
///   ([touchedKeys] tidak berisi kuncinya — seed segar yang belum
///   pernah kena penjualan/koreksi/harga di HP ini) -> ADOPSI
///   utuh dari server (qty + meta). Ini jalan HP baru / gerai yang
///   belum pernah dipakai di HP ini mendapat angka server yang
///   benar, bukan angka seed.
/// - level lokal sudah disentuh -> qty TIDAK PERNAH ditimpa dari
///   pull (qty digerakkan delta oleh mutasi; level absolut server
///   bisa ketinggalan) — hanya meta (unit, lowThreshold, cost)
///   yang diambil dari server, DAN hanya bila tidak ada mutasi
///   pending untuk nama itu ([pendingNames] — mutasi pending
///   membawa meta yang lebih baru dari server).
/// - item lokal yang tidak ada di server -> dibiarkan (bisa jadi
///   bahan baru yang mutasi pembuatannya belum terkirim).
StockMergePlan planStockMerge({
  required List<StockItem> local,
  required List<StockItem> server,
  required String outletId,
  required Set<String> touchedKeys,
  required Set<String> pendingNames,
}) {
  final localByName = <String, StockItem>{
    for (final s in local) s.name: s,
  };
  final toInsert = <StockItem>[];
  final toUpdate = <StockItem>[];
  for (final s in server) {
    if (s.name.isEmpty) continue;
    final existing = localByName[s.name];
    if (existing == null) {
      toInsert.add(s.copyWith(outletId: outletId));
      continue;
    }
    final key = stockTouchedKey(outletId, s.name);
    if (!touchedKeys.contains(key)) {
      // Seed segar — adopsi utuh dari server.
      toUpdate.add(s.copyWith(outletId: outletId));
      continue;
    }
    if (pendingNames.contains(s.name)) continue;
    toUpdate.add(existing.copyWith(
      unit: s.unit,
      lowThreshold: s.lowThreshold,
      costPerUnit: s.costPerUnit,
    ));
  }
  return (toInsert: toInsert, toUpdate: toUpdate);
}

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

  /// Nama bahan yang device ini PERNAH kirim mutasinya (kunci
  /// "$outletId|$name" — lihat [stockTouchedKey]). Dimuat sekali
  /// dari SELURUH outbox saat init + ditambah tiap enqueue mutasi
  /// (Batch C9 — dipakai merge pull: qty server hanya diadopsi
  /// bila bahan belum pernah disentuh di HP ini).
  Set<String> _touchedStockKeys = {};

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
    //
    // Batch C9: kunci "pernah disentuh" dimuat DULU dari outbox
    // (sebelum backfill mengantre event-nya sendiri) — lihat
    // [_loadTouchedKeys].
    await _loadTouchedKeys();
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
      // Batch C9: biaya hasil backfill HARUS sampai ke server —
      // kalau tidak, pull berikutnya menimpa biaya lokal dengan
      // cost server (0 = belum pernah ada mutasi yang membawa
      // biaya ini). Satu event 'koreksi' delta 0 per bahan yang
      // berubah. markTouched: false + flag backfill: true — backfill
      // BUKAN aktivitas kasir, jadi tidak boleh menghalangi adopsi
      // qty server di HP baru (lihat [_loadTouchedKeys]).
      for (var i = 0; i < filled.length; i++) {
        if (filled[i].costPerUnit == active[i].costPerUnit) continue;
        await _enqueueStockMovement(
          {
            'client_uuid': newClientUuid(),
            'outlet_id': _activeOutletId,
            'reason': 'koreksi',
            'backfill': true,
            'items': [
              {
                'name': filled[i].name,
                'unit': filled[i].unit,
                'qty_after': filled[i].qty,
                'low_threshold': filled[i].lowThreshold,
                'cost_per_unit': filled[i].costPerUnit.round(),
                'delta': 0,
              },
            ],
          },
          'backfill biaya (lokal tetap sah)',
          markTouched: false,
        );
      }
    }
    _initialized = true;
    notifyListeners();
  }

  /// Muat kunci "pernah disentuh" dari seluruh outbox (Batch C9).
  /// Event backfill biaya awal dilewati (flag `backfill: true`) —
  /// backfill bukan aktivitas kasir. Gagal baca = set kosong
  /// (aman: merge memperlakukan semua level sebagai seed segar —
  /// adopsi server).
  Future<void> _loadTouchedKeys() async {
    final keys = <String>{};
    try {
      final entries = await OutboxService.instance.allEntries();
      for (final entry in entries) {
        if (entry.kind != 'stock_movement') continue;
        final raw = jsonDecode(entry.payload);
        if (raw is! Map) continue;
        if (raw['backfill'] == true) continue;
        final outlet = raw['outlet_id'] is String
            ? raw['outlet_id'] as String
            : defaultOutletId;
        final items = raw['items'];
        if (items is List) {
          for (final it in items) {
            if (it is Map && it['name'] is String) {
              keys.add(stockTouchedKey(outlet, it['name'] as String));
            }
          }
        } else {
          // Payload lama pra-C6 (deductions/additions).
          for (final mapKey in const ['deductions', 'additions']) {
            final m = raw[mapKey];
            if (m is Map) {
              for (final name in m.keys) {
                keys.add(stockTouchedKey(outlet, name.toString()));
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Muat touched stok gagal (anggap kosong): $e');
    }
    _touchedStockKeys = keys;
  }

  /// Antrekan satu event mutasi stok + tandai bahan sebagai "pernah
  /// disentuh" (Batch C9 — kecuali [markTouched] false, dipakai
  /// backfill biaya awal yang tidak boleh menghalangi adopsi qty
  /// server di HP baru).
  Future<void> _enqueueStockMovement(
    Map<String, Object?> payload,
    String context, {
    bool markTouched = true,
  }) async {
    try {
      await OutboxService.instance.enqueueSale(
        payload,
        kind: 'stock_movement',
      );
      if (markTouched) {
        final outlet = payload['outlet_id'] as String? ?? _activeOutletId;
        final items = payload['items'];
        if (items is List) {
          for (final it in items) {
            if (it is Map && it['name'] is String) {
              _touchedStockKeys.add(
                stockTouchedKey(outlet, it['name'] as String),
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('StockService outbox mutasi gagal ($context): $e');
    }
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
  /// Batch C9: harga HARUS tersinkron — event 'stock_movement'
  /// reason 'koreksi', delta 0 (qty tidak berubah); server
  /// meng-update cost baris itu. syncNow langsung dipicu pemanggil
  /// (stok_page — StockService tidak boleh import SyncService).
  Future<bool> updateCost(String name, double cost) async {
    if (!isValidCost(cost)) return false;
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    final i = levels.indexWhere((s) => s.name == name);
    if (i < 0) return false;
    // Harga yang sama tidak perlu event (hindari spam outbox tiap
    // buka dialog lalu simpan tanpa ubah).
    if (levels[i].costPerUnit == cost) return true;
    final updated = [...levels];
    updated[i] = updated[i].copyWith(costPerUnit: cost);
    _levelsByOutlet[_activeOutletId] = updated;
    notifyListeners();
    await _saveOneLevel(updated[i]);
    await _enqueueStockMovement(
      {
        'client_uuid': newClientUuid(),
        'outlet_id': _activeOutletId,
        'reason': 'koreksi',
        'items': [
          {
            'name': name,
            'unit': updated[i].unit,
            'qty_after': updated[i].qty,
            'low_threshold': updated[i].lowThreshold,
            'cost_per_unit': cost.round(),
            'delta': 0,
          },
        ],
      },
      'ubah harga (lokal tetap sah)',
    );
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
  /// Batch C9: koreksi jumlah manual HARUS tersinkron — event
  /// 'stock_movement' reason 'koreksi' dengan delta = selisih
  /// (bisa positif/negatif); server menerapkan delta ke level
  /// gerai itu. syncNow langsung dipicu pemanggil (stok_page).
  Future<void> updateStock(
    String name,
    double qty,
    double lowThreshold,
  ) async {
    final levels = _levelsByOutlet[_activeOutletId] ?? const <StockItem>[];
    final i = levels.indexWhere((s) => s.name == name);
    if (i < 0) return;
    final before = levels[i];
    // Tidak ada yang berubah -> tidak ada event.
    if (before.qty == qty && before.lowThreshold == lowThreshold) return;
    final updated = [...levels];
    updated[i] = updated[i].copyWith(qty: qty, lowThreshold: lowThreshold);
    _levelsByOutlet[_activeOutletId] = updated;
    notifyListeners();
    await _saveOneLevel(updated[i]);
    await _enqueueStockMovement(
      {
        'client_uuid': newClientUuid(),
        'outlet_id': _activeOutletId,
        'reason': 'koreksi',
        'items': [
          {
            'name': name,
            'unit': before.unit,
            'qty_after': qty,
            'low_threshold': lowThreshold,
            'cost_per_unit':
                before.costPerUnit < 0 ? 0 : before.costPerUnit.round(),
            'delta': qty - before.qty,
          },
        ],
      },
      'koreksi stok (lokal tetap sah)',
    );
  }

  /// Tambah bahan baru di gerai aktif. false = nama sudah ada di
  /// gerai itu (Owner harus edit yang ada).
  /// Batch C9: bahan baru HARUS tersinkron — event 'stock_movement'
  /// reason 'tambah', delta = jumlah awal; server membuat baris
  /// stok gerai itu (qty_after = level awal). syncNow langsung
  /// dipicu pemanggil (stok_page; pemanggil topping_service
  /// mengandalkan timer 10 detik).
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
    await _enqueueStockMovement(
      {
        'client_uuid': newClientUuid(),
        'outlet_id': _activeOutletId,
        'reason': 'tambah',
        'items': [
          {
            'name': name,
            'unit': unit,
            'qty_after': qty,
            'low_threshold': lowThreshold,
            'cost_per_unit': 0,
            'delta': qty,
          },
        ],
      },
      'tambah bahan (lokal tetap sah)',
    );
    return true;
  }

  /// Gabungkan stok hasil pull server ke level lokal (Batch C9).
  /// Dipanggil SyncService.refreshSales tiap pull (10 detik).
  /// Rencana murni lewat [planStockMerge] (lihat aturan di sana).
  /// Tidak pernah throw; no-op bila belum init.
  Future<void> mergePulledStock(
    String outletId,
    List<StockItem> serverStock,
  ) async {
    if (!_initialized) return;
    final pendingNames = await _pendingMovementNames(outletId);
    final plan = planStockMerge(
      local: levelsFor(outletId),
      server: serverStock,
      outletId: outletId,
      touchedKeys: _touchedStockKeys,
      pendingNames: pendingNames,
    );
    if (plan.toInsert.isEmpty && plan.toUpdate.isEmpty) return;
    final updated = <String, StockItem>{
      for (final s in levelsFor(outletId)) s.name: s,
    };
    for (final item in [...plan.toInsert, ...plan.toUpdate]) {
      updated[item.name] = item;
    }
    _levelsByOutlet[outletId] = updated.values.toList();
    notifyListeners();
    for (final item in [...plan.toInsert, ...plan.toUpdate]) {
      await _saveOneLevel(item);
    }
  }

  /// Nama bahan yang masih punya event 'stock_movement' pending
  /// di outbox untuk gerai [outletId].
  Future<Set<String>> _pendingMovementNames(String outletId) async {
    final names = <String>{};
    try {
      final pending = await OutboxService.instance.pendingEntries();
      for (final entry in pending) {
        if (entry.kind != 'stock_movement') continue;
        final raw = jsonDecode(entry.payload);
        if (raw is! Map) continue;
        final outlet = raw['outlet_id'];
        if (outlet is String && outlet.isNotEmpty && outlet != outletId) {
          continue;
        }
        final items = raw['items'];
        if (items is List) {
          for (final it in items) {
            if (it is Map && it['name'] is String) {
              names.add(it['name'] as String);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Cek pending mutasi gagal: $e');
    }
    return names;
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
    await _enqueueStockMovement(
      {
        'client_uuid': newClientUuid(),
        'outlet_id': _activeOutletId,
        'reason': 'penjualan',
        if (transactionClientUuid != null)
          'transaction_client_uuid': transactionClientUuid,
        'items': syncItems,
      },
      'penjualan tetap sah',
    );
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
    await _enqueueStockMovement(
      {
        'client_uuid': newClientUuid(),
        'outlet_id': _activeOutletId,
        'reason': 'void',
        if (transactionClientUuid != null)
          'transaction_client_uuid': transactionClientUuid,
        'items': syncItems,
      },
      'void tetap sah',
    );
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
