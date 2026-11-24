import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'master_sync.dart';
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
    // Batch C10 WS0: topping baru = master-data.
    await _enqueueMaster(item);
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
    // Batch C10 WS0: ubah topping = master-data (rename bahan stok
    // sudah diantre sebagai master stock_item_config oleh
    // StockService.renameStock — di sini antre topping-nya).
    await _enqueueMaster(_toppings[i]);
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
    // Batch C10 WS0: toggle aktif = master-data.
    await _enqueueMaster(_toppings[i]);
  }

  /// Hapus topping (dengan konfirmasi di UI pemanggil).
  /// Bahan stoknya TETAP ADA — stoknya mungkin masih ada.
  /// Batch C10 WS0: hapus = is_deleted (HP lain nonaktifkan juga).
  Future<void> removeTopping(String id) async {
    final item = _toppings.where((t) => t.id == id).firstOrNull;
    if (item == null) return;
    _toppings = _toppings.where((t) => t.id != id).toList();
    notifyListeners();
    try {
      await (_database.delete(_database.toppings)
            ..where((t) => t.id.equals(id)))
          .go();
    } catch (e) {
      debugPrint('ToppingService hapus gagal simpan: $e');
    }
    await _enqueueMaster(item, isDeleted: true);
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

  // ===================== Master sync (Batch C10 WS0) =====================

  Future<void> _enqueueMaster(ToppingItem item, {bool isDeleted = false}) async {
    try {
      await OutboxService.instance.enqueueSale(
        MasterChange(
          entity: MasterEntity.topping,
          id: item.id,
          updatedAt: DateTime.now().toUtc(),
          isDeleted: isDeleted,
          data: {
            'id': item.id,
            'name': item.name,
            'price_delta': item.priceDelta,
            'active': isDeleted ? false : item.active,
          },
        ).toEventPayload(),
        kind: 'master',
      );
    } catch (e) {
      debugPrint('ToppingService antre master gagal: $e');
    }
  }

  /// Terapkan topping hasil pull server (Batch C10 WS0): perubahan
  /// yang menang LWW (bukan pending) diterapkan ke memori + Drift.
  /// Topping is_deleted = hapus lokal (bahan stoknya TETAP ADA).
  /// Topping BARU dari HP lain disisipkan (+ bahan stok porsi-nya).
  Future<void> mergePulledToppings(List<MasterChange> serverChanges) async {
    if (!_initialized) return;
    final pending = await OutboxService.instance.pendingMasterKeys();
    final localUpdatedAt = <String, DateTime>{};
    // Toppings tidak menyimpan updated_at — pakai epoch (server
    // menang bila ada perubahan; perubahan lokal yang belum terkirim
    // dilindungi pendingKeys 'topping|<id>').
    for (final t in _toppings) {
      localUpdatedAt['${MasterEntity.topping}|${t.id}'] =
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
      if (name.isEmpty && !change.isDeleted) continue;
      final i = _toppings.indexWhere((t) => t.id == change.id);
      if (change.isDeleted) {
        if (i < 0) continue;
        _toppings = _toppings.where((t) => t.id != change.id).toList();
        changed = true;
        try {
          await (_database.delete(_database.toppings)
                ..where((t) => t.id.equals(change.id)))
              .go();
        } catch (e) {
          debugPrint('ToppingService merge hapus gagal: $e');
        }
        continue;
      }
      final item = ToppingItem(
        id: change.id,
        name: name,
        priceDelta: (change.data['price_delta'] as num? ?? 0).toInt(),
        active: change.data['active'] as bool? ?? true,
      );
      if (i < 0) {
        _toppings = [..._toppings, item];
      } else {
        _toppings = List<ToppingItem>.of(_toppings)..[i] = item;
      }
      changed = true;
      try {
        await _database.into(_database.toppings).insert(
              ToppingsCompanion.insert(
                id: item.id,
                name: item.name,
                priceDelta: item.priceDelta,
                active: Value(item.active),
              ),
              mode: InsertMode.insertOrReplace,
            );
      } catch (e) {
        debugPrint('ToppingService merge simpan gagal: $e');
      }
      // Pastikan bahan stok porsi-nya ada (topping baru dari HP lain).
      if (!StockService.instance.stockByName.containsKey(item.name)) {
        await StockService.instance.addStockItem(item.name, 'porsi', 0, 0);
      }
    }
    if (changed) notifyListeners();
  }
}
