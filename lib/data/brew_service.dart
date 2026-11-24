import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'c10_models.dart';
import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'stock_service.dart';
import 'sync_payload.dart';

/// Masak Teh (Batch C10 WS4): Teh Kering -> Teh Masak, harian.
///
/// Aturan (brief §4 WS4):
/// - TIDAK ADA rasio asumsi: kg dipakai + liter dihasilkan diambil
///   dari masakan nyata (diisi Owner/Kasir), bukan dari resep.
/// - Teh Masak hanya bertahan SEHARI: tiap gerai punya satu
///   saldo Teh Masak + tanggal masak. Masak di hari baru =
///   hangus dulu sisa kemarin (movement 'kedaluwarsa', tercatat di
///   riwayat + laporan), baru saldo baru.
/// - Teh Masak = 0 -> menu teh "Habis" + shortcut Masak Teh.
/// - Biaya: Teh Masak per liter = (kg dipakai x harga Teh Kering)
///   / liter dihasilkan (weighted average — lihat [brew]).
class BrewService extends ChangeNotifier {
  BrewService._();

  static final BrewService instance = BrewService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<BrewRecord> _brews = [];
  Map<String, BrewState> _states = {};
  bool _initialized = false;

  bool get isInitialized => _initialized;

  List<BrewRecord> get brews => List.unmodifiable(_brews);

  /// Riwayat masak gerai [outletId], terbaru dulu.
  List<BrewRecord> brewsFor(String outletId) =>
      _brews.where((b) => b.outletId == outletId).toList();

  /// Status masak gerai [outletId] hari ini (null = belum pernah masak).
  BrewState? stateFor(String outletId) => _states[outletId];

  /// Sisa Teh Masak gerai [outletId] hari ini (0 bila belum masak /
  /// sudah hangus kemarin). Nilai ini = saldo di StockLevels — bukan
  /// dihitung ulang dari riwayat — jadi tidak bisa beda dari stok.
  double tehMasakToday(String outletId) {
    final stock = StockService.instance.stockByNameFor(outletId);
    return stock[tehMasakName]?.qty ?? 0;
  }

  /// Apakah gerai [outletId] masih punya Teh Masak yang BELUM hangus?
  /// False juga bila saldo 0 (mis. sesudah hangus — state tanggal
  /// diperbarui ke hari ini tapi liter 0; tanpa cek saldo, halaman
  /// Masak Teh akan menampilkan "masih segar" padahal kosong).
  /// State diambil dari [_states], jatuh ke riwayat masak bila HP
  /// ini belum punya baris state (masak dari HP lain — lihat
  /// [_stateFromHistory]).
  bool hasFreshTehMasak(String outletId) {
    final state = _states[outletId] ?? _stateFromHistory(outletId);
    if (state == null) return false;
    if (isBrewExpired(state.brewedDate, DateTime.now())) return false;
    return tehMasakToday(outletId) > 0;
  }

  /// State masak dari riwayat ([_brews] — termasuk baris pull dari
  /// HP lain): tanggal masak TERAKHIR gerai itu + total liter hari
  /// itu. Dipakai bila [_states] belum punya baris gerai itu, supaya
  /// hangus/segar tidak bergantung pada BrewStates lokal saja —
  /// riwayat masak tersinkron via pull (WS0/WS4), state lokal tidak.
  BrewState? _stateFromHistory(String outletId) {
    DateTime? latest;
    var liters = 0.0;
    for (final b in _brews) {
      if (b.outletId != outletId) continue;
      final day = DateTime(b.brewedAt.year, b.brewedAt.month, b.brewedAt.day);
      if (latest == null || day.isAfter(latest)) {
        latest = day;
        liters = b.litersMade;
      } else if (day == latest) {
        liters += b.litersMade;
      }
    }
    if (latest == null) return null;
    return BrewState(
      outletId: outletId,
      brewedDate: latest,
      litersMade: liters,
    );
  }

  /// Tulis state masak ke memori + tabel BrewStates (dipakai
  /// [_stateFromHistory] sesudah merge pull + sesudah hangus).
  Future<void> _saveState(BrewState state) async {
    _states[state.outletId] = state;
    try {
      await _database.into(_database.brewStates).insert(
            BrewStatesCompanion.insert(
              outletId: state.outletId,
              brewedDate: Value(state.brewedDate),
              litersMade: Value(state.litersMade),
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('BrewService simpan state gagal: $e');
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.brewRecords).get();
      _brews = rows
          .map(
            (r) => BrewRecord(
              id: r.id,
              outletId: r.outletId,
              kgUsed: r.kgUsed,
              litersMade: r.litersMade,
              brewedAt: r.brewedAt,
              brewedBy: r.brewedBy,
              expiredLiters: r.expiredLiters,
              updatedAt: r.updatedAt,
            ),
          )
          .toList()
        ..sort((a, b) => b.brewedAt.compareTo(a.brewedAt));
      final stateRows = await _database.select(_database.brewStates).get();
      _states = {
        for (final r in stateRows)
          if (r.brewedDate != null)
            r.outletId: BrewState(
              outletId: r.outletId,
              brewedDate: r.brewedDate!,
              litersMade: r.litersMade,
            ),
      };
    } catch (e) {
      debugPrint('BrewService init gagal: $e');
    }
    _initialized = true;
    notifyListeners();
  }

  /// Masak Teh (Batch C10 WS4): [kgUsed] Teh Kering -> [litersMade]
  /// Teh Masak. null = input tidak valid (kg/l <= 0 / Teh Kering
  /// di gerai kurang). Bila ada sisa kemarin -> hangus dulu
  /// (movement 'kedaluwarsa', alasan "hangus"). Atomik: Teh Kering
  /// −, Teh Masak + (atau diganti bila sudah hangus) — bila
  /// transfer gagal (stok berubah di tengah), TIDAK ada yang berubah.
  Future<BrewRecord?> brew({
    required String outletId,
    required double kgUsed,
    required double litersMade,
    String brewedBy = 'Kasir',
  }) async {
    if (kgUsed <= 0 || litersMade <= 0) return null;
    // Baris stok harus ada dulu: adjustLevels MELEWATI bahan yang
    // belum ada di level gerai (tidak membuat baris) — tanpa ini,
    // masak pertama di gerai yang belum pernah di-ensureOutlet akan
    // mengurangi Teh Kering tapi Teh Masak +liter HILANG diam-diam.
    await StockService.instance.ensureStockItem(
      outletId,
      tehKeringName,
      'kg',
    );
    await StockService.instance.ensureStockItem(
      outletId,
      tehMasakName,
      'liter',
    );
    final stock = StockService.instance.stockByNameFor(outletId);
    final haveKg = stock[tehKeringName]?.qty ?? 0;
    if (kgUsed > haveKg) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final state = _states[outletId];
    final expiredYesterday =
        state != null && isBrewExpired(state.brewedDate, now);
    // Sisa kemarin (bila hangus) harus dibuang DULU — jangan
    // dijumlah ke saldo baru.
    double carriedOver = 0;
    if (expiredYesterday) {
      carriedOver = await expireTehMasak(outletId, now: now);
    } else if (state != null && _isSameDay(state.brewedDate, now)) {
      carriedOver = stock[tehMasakName]?.qty ?? 0;
    }
    final deltas = <String, double>{
      tehKeringName: -kgUsed,
      // Teh Masak: buang dulu sisa kemarin (bila ada), lalu tambah
      // hasil masak hari ini. adjustLevels menjumlah delta ke saldo
      // sekarang — bila hangus, saldo sudah 0 (expireTehMasak).
      tehMasakName: litersMade,
    };
    final applied = await StockService.instance.adjustLevels(
      outletId,
      deltas,
      reason: 'brew',
      enqueueMovement: false,
    );
    if (applied.isEmpty) {
      // Transfer gagal total (race) — kembalikan sisa hangus bila
      // sempat dihanguskan (jarang: expire sukses, adjust gagal).
      if (carriedOver > 0) {
        await StockService.instance.adjustLevels(
          outletId,
          {tehMasakName: carriedOver},
          reason: 'brew',
          enqueueMovement: false,
        );
      }
      return null;
    }
    // Biaya Teh Masak per liter (weighted): (kg x harga Teh Kering)
    // / liter dihasilkan. costPerUnit lama = 0 (belum pernah masak)
    // atau rata-rata tertimbang dengan stok yang masih ada.
    final kgCost = StockService.instance.stockByNameFor(outletId)[tehKeringName]?.costPerUnit ?? 0;
    if (kgCost > 0) {
      final oldCost = stock[tehMasakName]?.costPerUnit ?? 0;
      final oldLiters = expiredYesterday ? 0.0 : carriedOver;
      final newLiters = oldLiters + litersMade;
      final newCost = newLiters > 0
          ? (oldCost * oldLiters + kgCost * kgUsed) / newLiters
          : 0.0;
      if (newCost > 0) {
        await StockService.instance.setCostFor(
          outletId,
          tehMasakName,
          newCost,
        );
      }
    }
    final id = newClientUuid();
    final record = BrewRecord(
      id: id,
      outletId: outletId,
      kgUsed: kgUsed,
      litersMade: litersMade,
      brewedAt: now,
      brewedBy: brewedBy,
      expiredLiters: expiredYesterday ? carriedOver : 0,
      updatedAt: now.toUtc(),
    );
    _brews = [record, ..._brews];
    _states[outletId] = BrewState(
      outletId: outletId,
      brewedDate: today,
      litersMade: (expiredYesterday ? 0.0 : carriedOver) + litersMade,
    );
    notifyListeners();
    try {
      await _database.into(_database.brewRecords).insert(
            BrewRecordsCompanion.insert(
              id: record.id,
              outletId: record.outletId,
              kgUsed: record.kgUsed,
              litersMade: record.litersMade,
              brewedAt: record.brewedAt,
              brewedBy: Value(record.brewedBy),
              expiredLiters: Value(record.expiredLiters),
              updatedAt: record.updatedAt,
            ),
          );
      await _database.into(_database.brewStates).insert(
            BrewStatesCompanion.insert(
              outletId: outletId,
              brewedDate: Value(today),
              litersMade: Value(_states[outletId]!.litersMade),
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('BrewService masak gagal simpan: $e');
    }
    try {
      await OutboxService.instance.enqueueSale(
        {
          'client_uuid': id,
          'brew_id': id,
          'outlet_id': outletId,
          'kg_used': kgUsed,
          'liters_made': litersMade,
          'brewed_at': toUtcIsoString(now),
          'brewed_by': brewedBy,
          'expired_liters': expiredYesterday ? carriedOver : 0.0,
          'updated_at': toUtcIsoString(now),
        },
        kind: 'brew',
      );
    } catch (e) {
      debugPrint('BrewService antre brew gagal: $e');
    }
    return record;
  }

  /// Hanguskan sisa Teh Masak kemarin (Batch C10 WS4): saldo Teh
  /// Masak gerai [outletId] dijadikan 0 via movement 'kedaluwarsa'
  /// (tercatat di riwayat + laporan ledger TERBUANG). Mengembalikan
  /// liter yang dihanguskan (0 bila tidak ada sisa / tidak hangus).
  /// Dipanggil: app start + tick 10 dtk (SyncService) + sebelum
  /// penjualan + di awal [brew].
  Future<double> expireTehMasak(String outletId, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    // State lokal dulu; bila HP ini belum pernah masak di gerai ini,
    // turunkan dari riwayat masak (termasuk pull HP lain).
    final state = _states[outletId] ?? _stateFromHistory(outletId);
    if (state == null) return 0;
    if (!isBrewExpired(state.brewedDate, at)) return 0;
    final stock = StockService.instance.stockByNameFor(outletId);
    final remaining = stock[tehMasakName]?.qty ?? 0;
    final today = DateTime(at.year, at.month, at.day);
    if (remaining > 0) {
      await StockService.instance.adjustLevels(
        outletId,
        {tehMasakName: -remaining},
        reason: 'kedaluwarsa',
      );
    }
    // Tandai sudah dihanguskan hari ini (jangan hangus lagi besok
    // dengan sisa yang sama — saldo sudah 0; tanggal diperbarui ke
    // hari ini supaya expiry check berikutnya diam).
    await _saveState(
      BrewState(outletId: outletId, brewedDate: today, litersMade: 0),
    );
    notifyListeners();
    return remaining;
  }

  /// Cek expiry untuk SEMUA gerai yang pernah masak (dipanggil dari
  /// SyncService.start tick 10 dtk + app start). Mengembalikan
  /// jumlah gerai yang dihanguskan.
  Future<int> expireCheck({List<String>? outletIds}) async {
    final ids = outletIds ?? _states.keys.toList();
    var count = 0;
    for (final id in ids) {
      final expired = await expireTehMasak(id);
      if (expired > 0) count++;
    }
    return count;
  }

  /// Terapkan riwayat masak hasil pull server (Batch C10 WS4):
  /// baris dari HP lain yang belum ada lokal disisipkan (dedupe by
  /// id). Saldo Teh Masak-nya sendiri datang dari mergePulledStock
  /// (server sudah menerapkan brew sebagai delta), bukan dari sini.
  Future<void> mergePulledBrews(List<Map<String, dynamic>> rows) async {
    if (!_initialized) return;
    final known = {for (final b in _brews) b.id};
    var changed = false;
    for (final row in rows) {
      final id = row['id'] as String? ?? row['client_uuid'] as String? ?? '';
      if (id.isEmpty || known.contains(id)) continue;
      final outletId = row['outlet_id'] as String? ?? '';
      final kg = (row['kg_used'] as num? ?? 0).toDouble();
      final liters = (row['liters_made'] as num? ?? 0).toDouble();
      if (outletId.isEmpty || kg <= 0 || liters <= 0) continue;
      final atRaw = row['brewed_at'] as String?;
      final at = atRaw == null
          ? DateTime.now()
          : DateTime.tryParse(atRaw)?.toLocal() ?? DateTime.now();
      final record = BrewRecord(
        id: id,
        outletId: outletId,
        kgUsed: kg,
        litersMade: liters,
        brewedAt: at,
        brewedBy: row['brewed_by'] as String? ?? 'Kasir',
        expiredLiters: (row['expired_liters'] as num? ?? 0).toDouble(),
        updatedAt: DateTime.now().toUtc(),
      );
      _brews = [record, ..._brews]
        ..sort((a, b) => b.brewedAt.compareTo(a.brewedAt));
      known.add(id);
      changed = true;
      try {
        await _database.into(_database.brewRecords).insert(
              BrewRecordsCompanion.insert(
                id: record.id,
                outletId: record.outletId,
                kgUsed: record.kgUsed,
                litersMade: record.litersMade,
                brewedAt: record.brewedAt,
                brewedBy: Value(record.brewedBy),
                expiredLiters: Value(record.expiredLiters),
                updatedAt: record.updatedAt,
              ),
            );
      } catch (e) {
        debugPrint('BrewService merge masak gagal: $e');
      }
    }
    if (changed) {
      // Riwayat berubah -> state masak tiap gerai yang tersentuh
      // dihitung ulang dari riwayat (tanggal masak terakhir + liter
      // hari itu) supaya hangus/segar jalan juga untuk masakan HP
      // lain — state tidak hanya dari BrewStates lokal.
      final touched = <String>{
        for (final row in rows)
          if (row['outlet_id'] is String) row['outlet_id'] as String,
      };
      for (final outletId in touched) {
        final derived = _stateFromHistory(outletId);
        if (derived != null) await _saveState(derived);
      }
      notifyListeners();
    }
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
