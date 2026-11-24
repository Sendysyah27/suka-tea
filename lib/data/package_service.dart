import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'c10_models.dart';
import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'master_sync.dart';
import 'stock_service.dart';
import 'sync_payload.dart';

/// Hasil kirim ke satu gerai (Batch C10 WS3).
class SendOutcome {
  const SendOutcome({
    required this.outletId,
    required this.ok,
    this.sendId,
    this.shortages = const [],
    this.message = '',
  });

  final String outletId;
  final bool ok;

  /// Id kiriman (bila ok) — dipakai "Coba lagi" sesudah gagal server.
  final String? sendId;
  final List<GudangShortage> shortages;
  final String message;
}

/// Pemberitahuan kiriman GAGAL dari server (Batch C10 WS3):
/// server menolak 'gudang_kurang' — stok lokal sudah dibalik,
/// Owner harus tahu + bisa "Coba lagi" dari halaman Kirim.
class FailedSendNotice {
  const FailedSendNotice({
    required this.sendId,
    required this.outletId,
    required this.message,
    required this.at,
    required this.items,
  });

  final String sendId;
  final String outletId;
  final String message;
  final DateTime at;

  /// Item kiriman yang gagal (untuk "Coba lagi" — isi ulang form).
  final List<SendItem> items;
}

/// Paket kiriman + stok masuk + kirim ke gerai + opname + target
/// (Batch C10 WS1/WS2/WS3/WS6/WS7 §4). Di memori (ChangeNotifier)
/// dan dicerminkan ke Drift. Semua tulis ke DB dibungkus try/catch
/// (pola StockService): gagal simpan tidak boleh crash app.
///
/// SINKRONISASI:
/// - Paket / item paket / default per gerai / target = master-data
///   (kind 'master' — lihat master_sync.dart, last-write-wins).
/// - Stok masuk = kind 'stock_in' (gudang += jumlah).
/// - Kirim ke gerai = kind 'stock_send' (gudang −, gerai +).
/// - Opname = kind 'opname' (per baris) + mutasi 'opname' saat
///   "Sesuaikan stok" ditekan (lihat adjustOpname).
class PackageService extends ChangeNotifier {
  PackageService._();

  static final PackageService instance = PackageService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<StockPackage> _packages = [];
  List<StockSend> _sends = [];
  List<StockOpname> _opnames = [];
  List<StockInRecord> _stockIns = [];
  Map<String, String?> _defaults = {};
  Map<String, GeraiTarget> _targets = {};
  List<FailedSendNotice> _failedNotices = [];
  bool _initialized = false;

  /// Semua paket (aktif + nonaktif — nonaktif = sudah dihapus Owner,
  /// dipertahankan untuk merge; UI hanya menampilkan yang aktif).
  List<StockPackage> get packages => List.unmodifiable(_packages);

  /// Paket AKTIF saja (untuk daftar + picker).
  List<StockPackage> get activePackages =>
      _packages.where((p) => p.isActive).toList();

  bool get isInitialized => _initialized;

  StockPackage? packageById(String id) {
    for (final p in _packages) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Paket default gerai [outletId] (null = belum diatur).
  String? defaultPackageIdFor(String outletId) => _defaults[outletId];

  StockPackage? defaultPackageFor(String outletId) {
    final id = _defaults[outletId];
    if (id == null) return null;
    return packageById(id);
  }

  /// Semua kiriman, terbaru dulu (semua gerai).
  List<StockSend> get sends => List.unmodifiable(_sends);

  /// Kiriman ke gerai [outletId] pada tanggal [day] (lokal).
  List<StockSend> sendsFor(String outletId, DateTime day) => _sends
      .where(
        (s) =>
            s.outletId == outletId &&
            s.sentAt.year == day.year &&
            s.sentAt.month == day.month &&
            s.sentAt.day == day.day,
      )
      .toList();

  /// Semua baris opname, terbaru dulu (semua gerai).
  List<StockOpname> get opnames => List.unmodifiable(_opnames);

  /// Baris opname gerai [outletId] (terbaru dulu).
  List<StockOpname> opnamesFor(String outletId) =>
      _opnames.where((o) => o.outletId == outletId).toList();

  /// Riwayat stok masuk gudang, terbaru dulu.
  List<StockInRecord> get stockIns => List.unmodifiable(_stockIns);

  /// Target omzet harian gerai [outletId] (0 = belum ada target).
  int targetFor(String outletId) => _targets[outletId]?.targetOmzet ?? 0;

  Map<String, GeraiTarget> get targets => Map.unmodifiable(_targets);

  /// Kiriman yang gagal di server + sudah dibalik lokal (untuk
  /// banner + "Coba lagi" di halaman Kirim / Dashboard).
  List<FailedSendNotice> get failedNotices =>
      List.unmodifiable(_failedNotices);

  void clearFailedNotice(String sendId) {
    _failedNotices = _failedNotices.where((n) => n.sendId != sendId).toList();
    notifyListeners();
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final pkgRows = await _database.select(_database.packages).get();
      final itemRows = await _database.select(_database.packageItems).get();
      final itemsByPkg = <String, List<PackageItem>>{};
      for (final r in itemRows) {
        (itemsByPkg[r.packageId] ??= []).add(
          PackageItem(
            id: r.id,
            packageId: r.packageId,
            stockName: r.stockName,
            qty: r.qty,
            unit: r.unit,
            updatedAt: r.updatedAt,
          ),
        );
      }
      _packages = pkgRows
          .map(
            (r) => StockPackage(
              id: r.id,
              name: r.name,
              note: r.note,
              isActive: r.isActive,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              items: itemsByPkg[r.id] ?? const [],
            ),
          )
          .toList();
      final defRows =
          await _database.select(_database.outletPackageDefaults).get();
      _defaults = {
        for (final r in defRows) r.outletId: r.packageId,
      };
      final sendRows = await _database.select(_database.stockSends).get();
      final sendItemRows = await _database.select(_database.sendItems).get();
      final itemsBySend = <String, List<SendItem>>{};
      for (final r in sendItemRows) {
        (itemsBySend[r.sendId] ??= []).add(
          SendItem(stockName: r.stockName, qty: r.qty, unit: r.unit),
        );
      }
      _sends = sendRows
          .map(
            (r) => StockSend(
              id: r.id,
              outletId: r.outletId,
              packageId: r.packageId,
              packageName: r.packageName,
              sentAt: r.sentAt,
              sentBy: r.sentBy,
              note: r.note,
              status: r.status,
              items: itemsBySend[r.id] ?? const [],
            ),
          )
          .toList()
        ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
      final opRows = await _database.select(_database.stockOpnames).get();
      _opnames = opRows
          .map(
            (r) => StockOpname(
              id: r.id,
              outletId: r.outletId,
              stockName: r.stockName,
              systemQty: r.systemQty,
              physicalQty: r.physicalQty,
              countedAt: r.countedAt,
              countedBy: r.countedBy,
              note: r.note,
              adjusted: r.adjusted,
              updatedAt: r.updatedAt,
            ),
          )
          .toList()
        ..sort((a, b) => b.countedAt.compareTo(a.countedAt));
      final inRows = await _database.select(_database.stockIns).get();
      _stockIns = inRows
          .map(
            (r) => StockInRecord(
              id: r.id,
              stockName: r.stockName,
              unit: r.unit,
              qty: r.qty,
              totalPrice: r.totalPrice,
              supplier: r.supplier,
              date: r.date,
              note: r.note,
              createdAt: r.createdAt,
            ),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final targetRows = await _database.select(_database.geraiTargets).get();
      _targets = {
        for (final r in targetRows)
          r.outletId: GeraiTarget(
            outletId: r.outletId,
            targetOmzet: r.targetOmzet,
            updatedAt: r.updatedAt,
          ),
      };
    } catch (e) {
      debugPrint('PackageService init gagal: $e');
    }
    _initialized = true;
    notifyListeners();
    // Template bawaan (Batch C10 WS2): HANYA bila belum ada paket
    // DAN belum ada riwayat kiriman/masuk (install C10 pertama) —
    // Owner yang sudah menghapus semua paket tidak dibuatkan lagi.
    if (_packages.isEmpty && _sends.isEmpty && _stockIns.isEmpty) {
      await _createDefaultTemplate();
    }
  }

  Future<void> _createDefaultTemplate() async {
    final template = defaultPackageTemplate(id: newClientUuid());
    _packages = [template];
    notifyListeners();
    try {
      await _database.into(_database.packages).insert(
            PackagesCompanion.insert(
              id: template.id,
              name: template.name,
              note: Value(template.note),
              isActive: const Value(true),
              createdAt: template.createdAt,
              updatedAt: template.updatedAt,
            ),
          );
      for (final item in template.items) {
        await _database.into(_database.packageItems).insert(
              PackageItemsCompanion.insert(
                id: item.id,
                packageId: item.packageId,
                stockName: item.stockName,
                qty: item.qty,
                unit: item.unit,
                updatedAt: item.updatedAt,
              ),
            );
      }
    } catch (e) {
      debugPrint('PackageService template gagal simpan: $e');
    }
    await _enqueueMaster(MasterChange(
      entity: MasterEntity.package,
      id: template.id,
      updatedAt: template.updatedAt,
      data: template.toMasterData(),
    ));
    for (final item in template.items) {
      await _enqueueMaster(MasterChange(
        entity: MasterEntity.packageItem,
        id: item.id,
        updatedAt: item.updatedAt,
        data: item.toMasterData(),
      ));
    }
  }

  Future<void> _enqueueMaster(MasterChange change) async {
    try {
      await OutboxService.instance.enqueueSale(
        change.toEventPayload(),
        kind: 'master',
      );
    } catch (e) {
      debugPrint('PackageService antre master gagal: $e');
    }
  }

  Future<void> _enqueueEvent(
    Map<String, Object?> payload, {
    required String kind,
  }) async {
    try {
      await OutboxService.instance.enqueueSale(payload, kind: kind);
    } catch (e) {
      debugPrint('PackageService antre $kind gagal: $e');
    }
  }

  // ===================== Paket (WS2) =====================

  /// Buat paket baru. null = nama kosong / sudah dipakai paket aktif
  /// lain / ada bahan dobel / ada jumlah <= 0.
  /// [items] = (nama bahan, jumlah, satuan) — satuan HARUS satuan
  /// baku bahan itu (dicek pemanggil; di sini hanya dicek > 0).
  Future<StockPackage?> createPackage({
    required String name,
    String note = '',
    required List<SendItem> items,
  }) async {
    final clean = name.trim();
    if (isPackageNameTaken(_packages, clean)) return null;
    final seen = <String>{};
    for (final it in items) {
      // Jumlah 0 DIIZINKAN (template bawaan "Paket Standar Harian"
      // dibuat dengan jumlah 0 — Owner mengisinya sekali; kirim
      // hanya mengirim item > 0, lihat sendToOutlets).
      if (it.qty < 0 || it.stockName.isEmpty) return null;
      if (!seen.add(it.stockName.toLowerCase())) return null;
    }
    final now = DateTime.now().toUtc();
    final id = newClientUuid();
    final pkg = StockPackage(
      id: id,
      name: clean,
      note: note.trim(),
      createdAt: now,
      updatedAt: now,
      items: [
        for (final it in items)
          PackageItem(
            id: newClientUuid(),
            packageId: id,
            stockName: it.stockName,
            qty: it.qty,
            unit: it.unit,
            updatedAt: now,
          ),
      ],
    );
    _packages = [..._packages, pkg];
    notifyListeners();
    try {
      await _database.into(_database.packages).insert(
            PackagesCompanion.insert(
              id: pkg.id,
              name: pkg.name,
              note: Value(pkg.note),
              isActive: const Value(true),
              createdAt: pkg.createdAt,
              updatedAt: pkg.updatedAt,
            ),
          );
      for (final item in pkg.items) {
        await _database.into(_database.packageItems).insert(
              PackageItemsCompanion.insert(
                id: item.id,
                packageId: item.packageId,
                stockName: item.stockName,
                qty: item.qty,
                unit: item.unit,
                updatedAt: item.updatedAt,
              ),
            );
      }
    } catch (e) {
      debugPrint('PackageService buat paket gagal simpan: $e');
    }
    await _enqueueMaster(MasterChange(
      entity: MasterEntity.package,
      id: pkg.id,
      updatedAt: now,
      data: pkg.toMasterData(),
    ));
    for (final item in pkg.items) {
      await _enqueueMaster(MasterChange(
        entity: MasterEntity.packageItem,
        id: item.id,
        updatedAt: now,
        data: item.toMasterData(),
      ));
    }
    return pkg;
  }

  /// Ubah paket (nama/catatan/item). false = paket tidak ada / nama
  /// bentrok / item tidak valid. Item yang hilang dari daftar baru =
  /// is_deleted; item baru/berubah = upsert.
  Future<bool> updatePackage(
    String id, {
    required String name,
    String note = '',
    required List<SendItem> items,
  }) async {
    final i = _packages.indexWhere((p) => p.id == id);
    if (i < 0) return false;
    final clean = name.trim();
    if (isPackageNameTaken(_packages, clean, excludeId: id)) return false;
    final seen = <String>{};
    for (final it in items) {
      if (it.qty < 0 || it.stockName.isEmpty) return false;
      if (!seen.add(it.stockName.toLowerCase())) return false;
    }
    final old = _packages[i];
    final now = DateTime.now().toUtc();
    final newItems = <PackageItem>[];
    final oldByName = {
      for (final it in old.items) it.stockName.toLowerCase(): it,
    };
    for (final it in items) {
      final existing = oldByName[it.stockName.toLowerCase()];
      newItems.add(
        PackageItem(
          id: existing?.id ?? newClientUuid(),
          packageId: id,
          stockName: it.stockName,
          qty: it.qty,
          unit: it.unit,
          updatedAt: now,
        ),
      );
    }
    final updated = old.copyWith(
      name: clean,
      note: note.trim(),
      updatedAt: now,
      items: newItems,
    );
    _packages = List<StockPackage>.of(_packages)..[i] = updated;
    notifyListeners();
    try {
      await (_database.update(_database.packages)
            ..where((t) => t.id.equals(id)))
          .write(PackagesCompanion(
            name: Value(clean),
            note: Value(note.trim()),
            updatedAt: Value(now),
          ));
      await (_database.delete(_database.packageItems)
            ..where((t) => t.packageId.equals(id)))
          .go();
      for (final item in newItems) {
        await _database.into(_database.packageItems).insert(
              PackageItemsCompanion.insert(
                id: item.id,
                packageId: item.packageId,
                stockName: item.stockName,
                qty: item.qty,
                unit: item.unit,
                updatedAt: item.updatedAt,
              ),
            );
      }
    } catch (e) {
      debugPrint('PackageService ubah paket gagal simpan: $e');
    }
    await _enqueueMaster(MasterChange(
      entity: MasterEntity.package,
      id: id,
      updatedAt: now,
      data: updated.toMasterData(),
    ));
    final newByName = {
      for (final it in newItems) it.stockName.toLowerCase(): it,
    };
    for (final item in newItems) {
      final existing = oldByName[item.stockName.toLowerCase()];
      if (existing != null &&
          existing.qty == item.qty &&
          existing.unit == item.unit) {
        continue;
      }
      await _enqueueMaster(MasterChange(
        entity: MasterEntity.packageItem,
        id: item.id,
        updatedAt: now,
        data: item.toMasterData(),
      ));
    }
    for (final oldItem in old.items) {
      if (newByName.containsKey(oldItem.stockName.toLowerCase())) continue;
      await _enqueueMaster(MasterChange(
        entity: MasterEntity.packageItem,
        id: oldItem.id,
        updatedAt: now,
        isDeleted: true,
        data: oldItem.toMasterData(),
      ));
    }
    return true;
  }

  /// Hapus paket (nonaktif + is_deleted). false = paket tidak ada /
  /// paket ini masih jadi default salah satu gerai (pesan di UI:
  /// pindahkan dulu default-nya).
  Future<bool> deletePackage(String id) async {
    final i = _packages.indexWhere((p) => p.id == id);
    if (i < 0) return false;
    if (_defaults.values.any((d) => d == id)) return false;
    final old = _packages[i];
    final now = DateTime.now().toUtc();
    final updated = old.copyWith(isActive: false, updatedAt: now);
    _packages = List<StockPackage>.of(_packages)..[i] = updated;
    notifyListeners();
    try {
      await (_database.update(_database.packages)
            ..where((t) => t.id.equals(id)))
          .write(PackagesCompanion(
            isActive: const Value(false),
            updatedAt: Value(now),
          ));
    } catch (e) {
      debugPrint('PackageService hapus paket gagal simpan: $e');
    }
    await _enqueueMaster(MasterChange(
      entity: MasterEntity.package,
      id: id,
      updatedAt: now,
      isDeleted: true,
      data: updated.toMasterData(),
    ));
    for (final item in old.items) {
      await _enqueueMaster(MasterChange(
        entity: MasterEntity.packageItem,
        id: item.id,
        updatedAt: now,
        isDeleted: true,
        data: item.toMasterData(),
      ));
    }
    return true;
  }

  /// Salin paket (nama + " (salinan)" — bila bentrok, tambah angka).
  Future<StockPackage?> copyPackage(String id) async {
    final src = packageById(id);
    if (src == null) return null;
    var name = '${src.name} (salinan)';
    var n = 2;
    while (isPackageNameTaken(_packages, name)) {
      name = '${src.name} (salinan $n)';
      n++;
    }
    return createPackage(
      name: name,
      note: src.note,
      items: [
        for (final it in src.items)
          SendItem(stockName: it.stockName, qty: it.qty, unit: it.unit),
      ],
    );
  }

  /// Atur paket default gerai [outletId] (null = hapus default).
  Future<void> setDefaultPackage(String outletId, String? packageId) async {
    final now = DateTime.now().toUtc();
    _defaults[outletId] = packageId;
    notifyListeners();
    try {
      await _database.into(_database.outletPackageDefaults).insert(
            OutletPackageDefaultsCompanion.insert(
              outletId: outletId,
              packageId: Value(packageId),
              updatedAt: now,
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('PackageService default paket gagal simpan: $e');
    }
    await _enqueueMaster(MasterChange(
      entity: MasterEntity.packageDefault,
      id: outletId,
      updatedAt: now,
      data: {'outlet_id': outletId, 'package_id': packageId},
    ));
  }

  /// Atur target omzet harian gerai [outletId] (Rp/hari, >= 0).
  Future<void> setTarget(String outletId, int targetOmzet) async {
    if (targetOmzet < 0) return;
    final now = DateTime.now().toUtc();
    _targets[outletId] = GeraiTarget(
      outletId: outletId,
      targetOmzet: targetOmzet,
      updatedAt: now,
    );
    notifyListeners();
    try {
      await _database.into(_database.geraiTargets).insert(
            GeraiTargetsCompanion.insert(
              outletId: outletId,
              targetOmzet: targetOmzet,
              updatedAt: now,
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('PackageService target gagal simpan: $e');
    }
    await _enqueueMaster(MasterChange(
      entity: MasterEntity.target,
      id: outletId,
      updatedAt: now,
      data: {'outlet_id': outletId, 'target_omzet': targetOmzet},
    ));
  }

  // ===================== Stok masuk (WS1) =====================

  /// Catat stok masuk gudang (Batch C10 WS1). null = input tidak
  /// valid (jumlah <= 0 / tanggal di masa depan / tanggal lebih dari
  /// 30 hari mundur / nama kosong).
  /// Gudang += jumlah (atomik lokal) + event 'stock_in' ke server.
  /// Harga beli TOTAL > 0 = costPerUnit baru (total / jumlah) —
  /// menggantikan harga lama bahan itu; 0 = harga tidak berubah.
  Future<StockInRecord?> recordStockIn({
    required String stockName,
    required String unit,
    required double qty,
    int totalPrice = 0,
    String supplier = '',
    required DateTime date,
    String note = '',
  }) async {
    final clean = stockName.trim();
    if (clean.isEmpty || qty <= 0 || totalPrice < 0) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    if (day.isAfter(today)) return null;
    if (today.difference(day).inDays > 30) return null;
    await StockService.instance.ensureStockItem(gudangOutletId, clean, unit);
    final id = newClientUuid();
    final record = StockInRecord(
      id: id,
      stockName: clean,
      unit: unit,
      qty: qty,
      totalPrice: totalPrice,
      supplier: supplier.trim(),
      date: day,
      note: note.trim(),
      createdAt: now,
    );
    // Gudang += jumlah — TANPA event mutasi (event 'stock_in' yang
    // membawa delta ke server; mutasi tambahan akan dobel).
    await StockService.instance.adjustLevels(
      gudangOutletId,
      {clean: qty},
      reason: 'stock_in',
      enqueueMovement: false,
    );
    if (totalPrice > 0) {
      final newCost = totalPrice / qty;
      await StockService.instance.setCostFor(
        gudangOutletId,
        clean,
        newCost,
      );
    }
    _stockIns = [record, ..._stockIns];
    notifyListeners();
    try {
      await _database.into(_database.stockIns).insert(
            StockInsCompanion.insert(
              id: record.id,
              stockName: record.stockName,
              unit: record.unit,
              qty: record.qty,
              totalPrice: Value(record.totalPrice),
              supplier: Value(record.supplier),
              date: record.date,
              note: Value(record.note),
              createdAt: record.createdAt,
            ),
          );
    } catch (e) {
      debugPrint('PackageService stok masuk gagal simpan: $e');
    }
    await _enqueueEvent(
      {
        'client_uuid': id,
        'stock_name': clean,
        'unit': unit,
        'qty': qty,
        'total_price': totalPrice,
        'supplier': supplier.trim(),
        'date': toUtcIsoString(day),
        'note': note.trim(),
        'created_at': toUtcIsoString(now),
      },
      kind: 'stock_in',
    );
    return record;
  }

  // ===================== Kirim ke gerai (WS3) =====================

  /// Kirim stok ke BANYAK gerai sekaligus (Batch C10 WS3):
  /// [outletIds] diproses SEQUENSIAL (satu per satu — bila gudang
  /// habis di tengah, gerai berikutnya gagal lokal, bukan setengah
  /// jalan). [packageId] = paket yang dikirim (null = kirim custom
  /// dari [customItems]). [customItems] dipakai bila packageId null
  /// (top-up / kirim tanpa paket).
  /// Per gerai: cek gudang dulu (lokal) -> transfer atomik
  /// (gudang −, gerai +) -> catat kiriman -> antre 'stock_send'.
  /// Server menolak ('gudang_kurang') BILA dua HP kirim bersamaan
  /// dan gudang ternyata kurang — penanganannya di
  /// [reverseFailedSend] (dipanggil SyncService sesudah push).
  Future<List<SendOutcome>> sendToOutlets({
    required List<String> outletIds,
    String? packageId,
    List<SendItem> customItems = const [],
    String note = '',
    String sentBy = 'Owner',
  }) async {
    final results = <SendOutcome>[];
    final gudangByName = StockService.instance.stockByNameFor(gudangOutletId);
    final pkg = packageId == null ? null : packageById(packageId);
    final baseItems = pkg == null
        ? customItems
        : [
            for (final it in pkg.items)
              if (it.qty > 0)
                SendItem(stockName: it.stockName, qty: it.qty, unit: it.unit),
          ];
    if (baseItems.isEmpty) {
      return [
        for (final outletId in outletIds)
          SendOutcome(
            outletId: outletId,
            ok: false,
            message: pkg == null
                ? 'Tidak ada bahan yang dikirim.'
                : 'Paket "${pkg.name}" masih kosong — isi jumlahnya dulu.',
          ),
      ];
    }
    for (final outletId in outletIds) {
      final shortages = checkGudang(baseItems, gudangByName);
      if (shortages.isNotEmpty) {
        results.add(SendOutcome(
          outletId: outletId,
          ok: false,
          shortages: shortages,
          message: 'Gudang kurang: ${shortages.map((s) => s.stockName).join(', ')}.',
        ));
        continue;
      }
      final deltas = {for (final it in baseItems) it.stockName: it.qty};
      final moved = await StockService.instance.transferStock(
        fromOutletId: gudangOutletId,
        toOutletId: outletId,
        items: deltas,
      );
      if (!moved) {
        // Gudang berubah di antara cek + transfer (kiriman lain di
        // HP ini) — perlakukan seperti kekurangan gudang.
        final now2 = StockService.instance.stockByNameFor(gudangOutletId);
        results.add(SendOutcome(
          outletId: outletId,
          ok: false,
          shortages: checkGudang(baseItems, now2),
          message: 'Gudang berubah saat kirim — coba lagi.',
        ));
        continue;
      }
      final sendId = newClientUuid();
      final send = StockSend(
        id: sendId,
        outletId: outletId,
        packageId: pkg?.id,
        packageName: pkg?.name ?? '',
        sentAt: DateTime.now(),
        sentBy: sentBy,
        note: note.trim(),
        items: baseItems,
      );
      _sends = [send, ..._sends];
      notifyListeners();
      try {
        await _database.into(_database.stockSends).insert(
              StockSendsCompanion.insert(
                id: send.id,
                outletId: send.outletId,
                packageId: Value(send.packageId),
                packageName: Value(send.packageName),
                sentAt: send.sentAt,
                sentBy: Value(send.sentBy),
                note: Value(send.note),
                status: const Value('ok'),
              ),
            );
        for (final it in baseItems) {
          await _database.into(_database.sendItems).insert(
                SendItemsCompanion.insert(
                  id: newClientUuid(),
                  sendId: send.id,
                  stockName: it.stockName,
                  qty: it.qty,
                  unit: it.unit,
                ),
              );
        }
      } catch (e) {
        debugPrint('PackageService kirim gagal simpan: $e');
      }
      await _enqueueEvent(
        {
          'client_uuid': sendId,
          'send_id': sendId,
          'outlet_id': outletId,
          'package_id': pkg?.id,
          'package_name': pkg?.name ?? '',
          'sent_at': toUtcIsoString(send.sentAt),
          'sent_by': sentBy,
          'note': note.trim(),
          'items': [for (final it in baseItems) it.toJson()],
        },
        kind: 'stock_send',
      );
      results.add(SendOutcome(outletId: outletId, ok: true, sendId: sendId));
    }
    return results;
  }

  /// Balik kiriman yang DITOLAK server ('gudang_kurang', Batch C10
  /// WS3): stok yang sudah terlanjur pindah lokal (gudang −, gerai
  /// +) dibalik — gerai −, gudang + — sebatas yang masih ada di
  /// gerai (bila sebagian sudah terjual, hanya sisa yang dibalik).
  /// Event 'stock_send' yang gagal DIHAPUS dari outbox (tidak boleh
  /// di-retry — kirim ulang = kiriman BARU). Kiriman ditandai
  /// 'gagal' + pemberitahuan masuk [_failedNotices] (banner +
  /// "Coba lagi" di halaman Kirim / Dashboard).
  Future<void> reverseFailedSend({
    required String sendId,
    required String message,
  }) async {
    final i = _sends.indexWhere((s) => s.id == sendId);
    if (i < 0) return;
    final send = _sends[i];
    if (send.status == 'gagal') return;
    final geraiByName = StockService.instance.stockByNameFor(send.outletId);
    final reversible = <String, double>{};
    for (final item in send.items) {
      final have = geraiByName[item.stockName]?.qty ?? 0;
      final back = item.qty <= have ? item.qty : have;
      if (back > 0) reversible[item.stockName] = back;
    }
    if (reversible.isNotEmpty) {
      await StockService.instance.transferStock(
        fromOutletId: send.outletId,
        toOutletId: gudangOutletId,
        items: reversible,
      );
    }
    _sends = List<StockSend>.of(_sends)..[i] = send.copyWith(status: 'gagal');
    _failedNotices = [
      FailedSendNotice(
        sendId: sendId,
        outletId: send.outletId,
        message: message,
        at: DateTime.now(),
        items: send.items,
      ),
      ..._failedNotices,
    ];
    notifyListeners();
    try {
      await (_database.update(_database.stockSends)
            ..where((t) => t.id.equals(sendId)))
          .write(const StockSendsCompanion(status: Value('gagal')));
    } catch (e) {
      debugPrint('PackageService balik kirim gagal simpan: $e');
    }
    // Hapus event 'stock_send' yang gagal dari outbox (jangan retry).
    try {
      final pending = await OutboxService.instance.pendingEntries();
      final ids = <String>[];
      for (final entry in pending) {
        if (entry.kind != 'stock_send') continue;
        final raw = entry.payload;
        if (raw.contains('"$sendId"')) ids.add(entry.id);
      }
      if (ids.isNotEmpty) {
        await OutboxService.instance.deleteEntries(ids);
      }
    } catch (e) {
      debugPrint('PackageService hapus event kirim gagal: $e');
    }
  }

  // ===================== Opname (WS6) =====================

  /// Simpan satu sesi opname (Batch C10 WS6): [rows] = bahan yang
  /// DIHITUNG saja (bahan yang tidak dihitung = tidak ada barisnya —
  /// JANGAN isi 0 untuk yang belum dihitung). Tiap baris = satu
  /// event 'opname' (client_uuid = id baris). Stok TIDAK berubah di
  /// sini — penyesuaian hanya lewat [adjustOpname] (eksplisit).
  Future<List<StockOpname>> saveOpname({
    required String outletId,
    required List<StockOpname> rows,
    required String countedBy,
  }) async {
    final now = DateTime.now();
    final saved = <StockOpname>[];
    for (final row in rows) {
      final item = StockOpname(
        id: newClientUuid(),
        outletId: outletId,
        stockName: row.stockName,
        systemQty: row.systemQty,
        physicalQty: row.physicalQty,
        countedAt: now,
        countedBy: countedBy,
        note: row.note,
        updatedAt: now.toUtc(),
      );
      saved.add(item);
      try {
        await _database.into(_database.stockOpnames).insert(
              StockOpnamesCompanion.insert(
                id: item.id,
                outletId: item.outletId,
                stockName: item.stockName,
                systemQty: item.systemQty,
                physicalQty: item.physicalQty,
                countedAt: item.countedAt,
                countedBy: Value(item.countedBy),
                note: Value(item.note),
                adjusted: const Value(false),
                updatedAt: item.updatedAt,
              ),
            );
      } catch (e) {
        debugPrint('PackageService opname gagal simpan: $e');
      }
      await _enqueueEvent(
        {
          'client_uuid': item.id,
          'opname_id': item.id,
          'outlet_id': outletId,
          'stock_name': item.stockName,
          'system_qty': item.systemQty,
          'physical_qty': item.physicalQty,
          'difference': item.difference,
          'counted_at': toUtcIsoString(now),
          'counted_by': countedBy,
          'note': item.note,
          'adjusted': false,
          'updated_at': toUtcIsoString(now),
        },
        kind: 'opname',
      );
    }
    _opnames = [...saved, ..._opnames]
      ..sort((a, b) => b.countedAt.compareTo(a.countedAt));
    notifyListeners();
    return saved;
  }

  /// "Sesuaikan stok" untuk SATU baris opname (Batch C10 WS6 —
  /// eksplisit, tidak pernah otomatis): stok sistem gerai berubah
  /// sebesar selisih (fisik − sistem) via mutasi 'opname' + baris
  /// ditandai adjusted + event 'opname' (adjusted=true) ke server.
  /// false = baris tidak ada / sudah disesuaikan / selisih 0.
  Future<bool> adjustOpname(String opnameId) async {
    final i = _opnames.indexWhere((o) => o.id == opnameId);
    if (i < 0) return false;
    final row = _opnames[i];
    if (row.adjusted) return false;
    if (row.difference == 0) return false;
    final applied = await StockService.instance.adjustLevels(
      row.outletId,
      {row.stockName: row.difference},
      reason: 'opname',
    );
    if (applied.isEmpty) return false;
    final updated = row.copyWith(
      adjusted: true,
      updatedAt: DateTime.now().toUtc(),
    );
    _opnames = List<StockOpname>.of(_opnames)..[i] = updated;
    notifyListeners();
    try {
      await (_database.update(_database.stockOpnames)
            ..where((t) => t.id.equals(opnameId)))
          .write(StockOpnamesCompanion(
            adjusted: const Value(true),
            updatedAt: Value(updated.updatedAt),
          ));
    } catch (e) {
      debugPrint('PackageService sesuaikan opname gagal simpan: $e');
    }
    await _enqueueEvent(
      {
        'client_uuid': opnameId,
        'opname_id': opnameId,
        'outlet_id': row.outletId,
        'stock_name': row.stockName,
        'system_qty': row.systemQty,
        'physical_qty': row.physicalQty,
        'difference': row.difference,
        'counted_at': toUtcIsoString(row.countedAt),
        'counted_by': row.countedBy,
        'note': row.note,
        'adjusted': true,
        'updated_at': toUtcIsoString(updated.updatedAt),
      },
      kind: 'opname',
    );
    return true;
  }

  // ===================== Merge pull (WS0/WS3/WS6) =====================

  /// Terapkan master-data hasil pull server (Batch C10 WS0):
  /// paket / item paket / default per gerai / target. Perubahan yang
  /// menang LWW (bukan pending) diterapkan ke memori + Drift.
  Future<void> mergePulledMaster(List<MasterChange> serverChanges) async {
    if (!_initialized) return;
    final pending = await OutboxService.instance.pendingMasterKeys();
    final localUpdatedAt = <String, DateTime>{};
    for (final p in _packages) {
      localUpdatedAt['${MasterEntity.package}|${p.id}'] = p.updatedAt;
      for (final it in p.items) {
        localUpdatedAt['${MasterEntity.packageItem}|${it.id}'] = it.updatedAt;
      }
    }
    for (final entry in _defaults.entries) {
      // Default tanpa updatedAt tersimpan — pakai epoch (server menang
      // bila ada perubahan; default lokal yang belum terkirim
      // dilindungi pendingKeys).
      localUpdatedAt['${MasterEntity.packageDefault}|${entry.key}'] =
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    for (final t in _targets.values) {
      localUpdatedAt['${MasterEntity.target}|${t.outletId}'] = t.updatedAt;
    }
    final plan = planMasterMerge(
      serverChanges: serverChanges,
      localUpdatedAt: localUpdatedAt,
      pendingKeys: pending,
    );
    if (plan.isEmpty) return;
    var changed = false;
    for (final change in plan) {
      switch (change.entity) {
        case MasterEntity.package:
          changed = await _applyPackageChange(change) || changed;
        case MasterEntity.packageItem:
          changed = await _applyPackageItemChange(change) || changed;
        case MasterEntity.packageDefault:
          changed = await _applyDefaultChange(change) || changed;
        case MasterEntity.target:
          changed = await _applyTargetChange(change) || changed;
        default:
          continue;
      }
    }
    if (changed) notifyListeners();
  }

  Future<bool> _applyPackageChange(MasterChange change) async {
    final name = change.data['name'] as String? ?? '';
    if (name.isEmpty) return false;
    final i = _packages.indexWhere((p) => p.id == change.id);
    if (change.isDeleted) {
      if (i < 0) return false;
      // Paket dihapus di HP lain — nonaktifkan lokal (bukan hapus
      // fisik). Bila paket ini masih default gerai, default ikut
      // dihapus (tidak bisa kirim paket yang sudah tidak ada).
      _packages = List<StockPackage>.of(_packages)
        ..[i] = _packages[i].copyWith(isActive: false, updatedAt: change.updatedAt);
      _defaults.removeWhere((_, v) => v == change.id);
      try {
        await (_database.update(_database.packages)
              ..where((t) => t.id.equals(change.id)))
            .write(PackagesCompanion(
              isActive: const Value(false),
              updatedAt: Value(change.updatedAt),
            ));
      } catch (e) {
        debugPrint('PackageService merge paket hapus gagal: $e');
      }
      return true;
    }
    final note = change.data['note'] as String? ?? '';
    if (i < 0) {
      final pkg = StockPackage(
        id: change.id,
        name: name,
        note: note,
        createdAt: change.updatedAt,
        updatedAt: change.updatedAt,
        items: const [],
      );
      _packages = [..._packages, pkg];
      try {
        await _database.into(_database.packages).insert(
              PackagesCompanion.insert(
                id: pkg.id,
                name: pkg.name,
                note: Value(pkg.note),
                isActive: const Value(true),
                createdAt: pkg.createdAt,
                updatedAt: pkg.updatedAt,
              ),
            );
      } catch (e) {
        debugPrint('PackageService merge paket baru gagal: $e');
      }
      return true;
    }
    final updated = _packages[i].copyWith(
      name: name,
      note: note,
      isActive: true,
      updatedAt: change.updatedAt,
    );
    _packages = List<StockPackage>.of(_packages)..[i] = updated;
    try {
      await (_database.update(_database.packages)
            ..where((t) => t.id.equals(change.id)))
          .write(PackagesCompanion(
            name: Value(name),
            note: Value(note),
            isActive: const Value(true),
            updatedAt: Value(change.updatedAt),
          ));
    } catch (e) {
      debugPrint('PackageService merge paket ubah gagal: $e');
    }
    return true;
  }

  Future<bool> _applyPackageItemChange(MasterChange change) async {
    final packageId = change.data['package_id'] as String? ?? '';
    final stockName = change.data['stock_name'] as String? ?? '';
    if (packageId.isEmpty || stockName.isEmpty) return false;
    final pi = _packages.indexWhere((p) => p.id == packageId);
    if (pi < 0) return false;
    final pkg = _packages[pi];
    final ii = pkg.items.indexWhere((it) => it.id == change.id);
    if (change.isDeleted) {
      if (ii < 0) return false;
      final items = List<PackageItem>.of(pkg.items)..removeAt(ii);
      _packages = List<StockPackage>.of(_packages)
        ..[pi] = pkg.copyWith(items: items);
      try {
        await (_database.delete(_database.packageItems)
              ..where((t) => t.id.equals(change.id)))
            .go();
      } catch (e) {
        debugPrint('PackageService merge item hapus gagal: $e');
      }
      return true;
    }
    final qty = (change.data['qty'] as num? ?? 0).toDouble();
    final unit = change.data['unit'] as String? ?? 'pcs';
    if (qty < 0) return false;
    final item = PackageItem(
      id: change.id,
      packageId: packageId,
      stockName: stockName,
      qty: qty,
      unit: unit,
      updatedAt: change.updatedAt,
    );
    final items = List<PackageItem>.of(pkg.items);
    if (ii < 0) {
      items.add(item);
    } else {
      items[ii] = item;
    }
    _packages = List<StockPackage>.of(_packages)
      ..[pi] = pkg.copyWith(items: items);
    try {
      await _database.into(_database.packageItems).insert(
            PackageItemsCompanion.insert(
              id: item.id,
              packageId: item.packageId,
              stockName: item.stockName,
              qty: item.qty,
              unit: item.unit,
              updatedAt: item.updatedAt,
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('PackageService merge item gagal: $e');
    }
    return true;
  }

  Future<bool> _applyDefaultChange(MasterChange change) async {
    final outletId = change.data['outlet_id'] as String? ?? '';
    if (outletId.isEmpty) return false;
    final packageId = change.data['package_id'] as String?;
    _defaults[outletId] = packageId;
    try {
      await _database.into(_database.outletPackageDefaults).insert(
            OutletPackageDefaultsCompanion.insert(
              outletId: outletId,
              packageId: Value(packageId),
              updatedAt: change.updatedAt,
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('PackageService merge default gagal: $e');
    }
    return true;
  }

  Future<bool> _applyTargetChange(MasterChange change) async {
    final outletId = change.data['outlet_id'] as String? ?? '';
    if (outletId.isEmpty) return false;
    final target = (change.data['target_omzet'] as num? ?? 0).toInt();
    if (target < 0) return false;
    _targets[outletId] = GeraiTarget(
      outletId: outletId,
      targetOmzet: target,
      updatedAt: change.updatedAt,
    );
    try {
      await _database.into(_database.geraiTargets).insert(
            GeraiTargetsCompanion.insert(
              outletId: outletId,
              targetOmzet: target,
              updatedAt: change.updatedAt,
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('PackageService merge target gagal: $e');
    }
    return true;
  }

  /// Terapkan kiriman hasil pull server (Batch C10 WS3): kiriman
  /// dari HP lain yang belum ada lokal disisipkan (dedupe by id).
  /// Kiriman 'gagal' server ikut tersimpan (status ikut).
  Future<void> mergePulledSends(List<Map<String, dynamic>> rows) async {
    if (!_initialized) return;
    final known = {for (final s in _sends) s.id};
    var changed = false;
    for (final row in rows) {
      final id = row['id'] as String? ?? row['client_uuid'] as String? ?? '';
      if (id.isEmpty || known.contains(id)) continue;
      final outletId = row['outlet_id'] as String? ?? '';
      if (outletId.isEmpty) continue;
      final sentAtRaw = row['sent_at'] as String?;
      final sentAt =
          sentAtRaw == null ? DateTime.now() : DateTime.tryParse(sentAtRaw)?.toLocal() ?? DateTime.now();
      final itemsRaw = row['items'];
      final items = <SendItem>[];
      if (itemsRaw is List) {
        for (final it in itemsRaw) {
          if (it is! Map) continue;
          final name = it['stock_name'] as String? ?? it['name'] as String? ?? '';
          final qty = (it['qty'] as num? ?? 0).toDouble();
          if (name.isEmpty || qty <= 0) continue;
          items.add(SendItem(
            stockName: name,
            qty: qty,
            unit: it['unit'] as String? ?? 'pcs',
          ));
        }
      }
      final send = StockSend(
        id: id,
        outletId: outletId,
        packageId: row['package_id'] as String?,
        packageName: row['package_name'] as String? ?? '',
        sentAt: sentAt,
        sentBy: row['sent_by'] as String? ?? 'Owner',
        note: row['note'] as String? ?? '',
        status: row['status'] as String? ?? 'ok',
        items: items,
      );
      _sends = [send, ..._sends]
        ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
      known.add(id);
      changed = true;
      try {
        await _database.into(_database.stockSends).insert(
              StockSendsCompanion.insert(
                id: send.id,
                outletId: send.outletId,
                packageId: Value(send.packageId),
                packageName: Value(send.packageName),
                sentAt: send.sentAt,
                sentBy: Value(send.sentBy),
                note: Value(send.note),
                status: Value(send.status),
              ),
              mode: InsertMode.insertOrReplace,
            );
        for (final it in items) {
          await _database.into(_database.sendItems).insert(
                SendItemsCompanion.insert(
                  id: newClientUuid(),
                  sendId: send.id,
                  stockName: it.stockName,
                  qty: it.qty,
                  unit: it.unit,
                ),
              );
        }
      } catch (e) {
        debugPrint('PackageService merge kiriman gagal: $e');
      }
    }
    if (changed) notifyListeners();
  }

  /// Terapkan opname hasil pull server (Batch C10 WS6): baris dari
  /// HP lain yang belum ada lokal disisipkan; baris yang sama id-nya
  /// tapi adjusted=true di server -> tandai adjusted lokal juga
  /// (stoknya SUDAH diubah di HP yang menekan "Sesuaikan" — HP ini
  /// TIDAK mengubah lagi, hanya menandai).
  Future<void> mergePulledOpnames(List<Map<String, dynamic>> rows) async {
    if (!_initialized) return;
    var changed = false;
    for (final row in rows) {
      final id = row['id'] as String? ?? row['client_uuid'] as String? ?? '';
      if (id.isEmpty) continue;
      final i = _opnames.indexWhere((o) => o.id == id);
      final adjusted = row['adjusted'] == true;
      if (i >= 0) {
        if (adjusted && !_opnames[i].adjusted) {
          _opnames = List<StockOpname>.of(_opnames)
            ..[i] = _opnames[i].copyWith(adjusted: true);
          changed = true;
          try {
            await (_database.update(_database.stockOpnames)
                  ..where((t) => t.id.equals(id)))
                .write(const StockOpnamesCompanion(adjusted: Value(true)));
          } catch (e) {
            debugPrint('PackageService merge opname flag gagal: $e');
          }
        }
        continue;
      }
      final outletId = row['outlet_id'] as String? ?? '';
      final stockName = row['stock_name'] as String? ?? '';
      if (outletId.isEmpty || stockName.isEmpty) continue;
      final countedRaw = row['counted_at'] as String?;
      final countedAt = countedRaw == null
          ? DateTime.now()
          : DateTime.tryParse(countedRaw)?.toLocal() ?? DateTime.now();
      final opname = StockOpname(
        id: id,
        outletId: outletId,
        stockName: stockName,
        systemQty: (row['system_qty'] as num? ?? 0).toDouble(),
        physicalQty: (row['physical_qty'] as num? ?? 0).toDouble(),
        countedAt: countedAt,
        countedBy: row['counted_by'] as String? ?? 'Owner',
        note: row['note'] as String? ?? '',
        adjusted: adjusted,
        updatedAt: DateTime.now().toUtc(),
      );
      _opnames = [opname, ..._opnames]
        ..sort((a, b) => b.countedAt.compareTo(a.countedAt));
      changed = true;
      try {
        await _database.into(_database.stockOpnames).insert(
              StockOpnamesCompanion.insert(
                id: opname.id,
                outletId: opname.outletId,
                stockName: opname.stockName,
                systemQty: opname.systemQty,
                physicalQty: opname.physicalQty,
                countedAt: opname.countedAt,
                countedBy: Value(opname.countedBy),
                note: Value(opname.note),
                adjusted: Value(opname.adjusted),
                updatedAt: opname.updatedAt,
              ),
            );
      } catch (e) {
        debugPrint('PackageService merge opname baru gagal: $e');
      }
    }
    if (changed) notifyListeners();
  }

  /// Terapkan stok masuk hasil pull server (Batch C10 WS1 — gudang):
  /// baris dari HP lain yang belum ada lokal disisipkan.
  /// Stok gudang-nya sendiri datang dari mergePulledStock gudang
  /// (SyncService.refreshWarehouse), bukan dari sini.
  Future<void> mergePulledStockIns(List<Map<String, dynamic>> rows) async {
    if (!_initialized) return;
    final known = {for (final r in _stockIns) r.id};
    var changed = false;
    for (final row in rows) {
      final id = row['id'] as String? ?? row['client_uuid'] as String? ?? '';
      if (id.isEmpty || known.contains(id)) continue;
      final name = row['stock_name'] as String? ?? '';
      final qty = (row['qty'] as num? ?? 0).toDouble();
      if (name.isEmpty || qty <= 0) continue;
      final dateRaw = row['date'] as String?;
      final date = dateRaw == null
          ? DateTime.now()
          : DateTime.tryParse(dateRaw)?.toLocal() ?? DateTime.now();
      final createdRaw = row['created_at'] as String?;
      final createdAt = createdRaw == null
          ? DateTime.now()
          : DateTime.tryParse(createdRaw)?.toLocal() ?? DateTime.now();
      final record = StockInRecord(
        id: id,
        stockName: name,
        unit: row['unit'] as String? ?? 'pcs',
        qty: qty,
        totalPrice: (row['total_price'] as num? ?? 0).toInt(),
        supplier: row['supplier'] as String? ?? '',
        date: date,
        note: row['note'] as String? ?? '',
        createdAt: createdAt,
      );
      _stockIns = [record, ..._stockIns]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      known.add(id);
      changed = true;
      try {
        await _database.into(_database.stockIns).insert(
              StockInsCompanion.insert(
                id: record.id,
                stockName: record.stockName,
                unit: record.unit,
                qty: record.qty,
                totalPrice: Value(record.totalPrice),
                supplier: Value(record.supplier),
                date: record.date,
                note: Value(record.note),
                createdAt: record.createdAt,
              ),
            );
      } catch (e) {
        debugPrint('PackageService merge stok masuk gagal: $e');
      }
    }
    if (changed) notifyListeners();
  }
}
