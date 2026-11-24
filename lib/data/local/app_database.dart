import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Outbox idempoten untuk sinkronisasi offline -> online.
/// Setiap transaksi dibuat dulu di sini (status pending) dengan
/// client_uuid, lalu dikirim ke Supabase saat online. Transaksi &
/// mutasi stok bersifat append-only; konflik tidak di-overwrite.
class OutboxEntries extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()(); // contoh: 'transaction', 'stock_movement'
  TextColumn get payload => text()(); // JSON
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Cache menu lokal supaya kasir tetap jalan saat offline.
/// Sumber kebenaran tetap Supabase; tabel ini hanya cermin.
class LocalProducts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get category => text()();
  IntColumn get priceReguler => integer()();
  IntColumn get priceJumbo => integer()();
  TextColumn get photoUrl => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Stok bahan baku lokal (cermin seedStock + editan Owner).
/// Satu baris per (outlet, nama bahan) — Batch C8.2 WS5: stok
/// DIPISAH per gerai (tiap gerai punya bahan baku sendiri; Gerai 1
/// pakai teh tidak mengurangi Gerai 2). [outletId] = gerai pemilik
/// baris ini. [costPerUnit] = harga bahan per satuan (rupiah) —
/// DITENTUKAN Owner di tab Stok (Batch C1b). -1 = belum diatur
/// (HPP bahan itu Rp0); 0 = gratis (sengaja).
/// [shelfLifeDays] (Batch C10 WS4): masa simpan bahan dalam hari —
/// 0 = tidak pernah kedaluwarsa; 'Teh Masak' = 1 (hangus tiap
/// ganti hari). Gudang = baris dengan outletId = GUDANG_ID
/// (pseudo-outlet, lihat c10_models.dart) — TIDAK pernah di-seed.
class StockLevels extends Table {
  TextColumn get outletId => text().withDefault(
        const Constant('00000000-0000-0000-0000-000000000001'),
      )();
  TextColumn get name => text()();
  TextColumn get unit => text()();
  RealColumn get qty => real()();
  RealColumn get lowThreshold => real()();
  RealColumn get costPerUnit => real().withDefault(const Constant(-1))();
  IntColumn get shelfLifeDays => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {outletId, name};
}

/// Resep lokal: tiap varian memakai sejumlah bahan per cup.
/// Kunci gabungan (variantId, stockName) — satu bahan max 1x per varian.
class ProductRecipes extends Table {
  TextColumn get variantId => text()();
  TextColumn get stockName => text()();
  RealColumn get qty => real()();

  @override
  Set<Column> get primaryKey => {variantId, stockName};
}

/// Riwayat penjualan selesai (lokal, append-only). Satu baris per
/// transaksi yang sudah dibayar. itemsJson = daftar SaleItem (JSON).
/// Dipakai tab Keuangan + Laporan (data nyata) dan halaman Riwayat.
/// [discount] = diskon manual transaksi ini (0 bila tanpa diskon);
/// total yang disimpan = subtotal - diskon. [isVoid] = transaksi
/// dibatalkan Owner (stok dikembalikan, tidak dihitung di omzet).
/// [outletId] = gerai tempat transaksi terjadi (Batch C4) — baris lama
/// (sebelum v6) memakai outlet utama (...0001).
/// [qrisAmount]/[cashAmount] = bagian QRIS + tunai untuk transaksi
/// split (Batch C2); transaksi non-split = 0. paid = qrisAmount +
/// cashAmount (tunai yang DITERIMA — bisa lebih dari sisa tunai,
/// selisihnya kembalian); total tetap subtotal - diskon.
/// [cashierId]/[cashierName] = kasir pencatat (Batch C8.2 WS4 —
/// identitas dari server; Owner = '' / 'Owner'; baris lama = '' /
/// 'Kasir' bila kosong saat tampil).
class SaleHistory extends Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get itemsJson => text()();
  IntColumn get total => integer()();
  TextColumn get method => text()();
  IntColumn get paid => integer()();
  IntColumn get change => integer()();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  BoolColumn get isVoid => boolean().withDefault(const Constant(false))();
  TextColumn get outletId => text().withDefault(
        const Constant('00000000-0000-0000-0000-000000000001'),
      )();
  IntColumn get qrisAmount => integer().withDefault(const Constant(0))();
  IntColumn get cashAmount => integer().withDefault(const Constant(0))();
  TextColumn get cashierId => text().withDefault(const Constant(''))();
  TextColumn get cashierName => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Order Pending di Kasir (Batch C1). Satu baris per keranjang
/// yang disimpan sebagai Pending; itemsJson = daftar CartItem (JSON).
/// Label otomatis "Pending N • HH:mm". Pulihkan = hapus baris + isi
/// kembali keranjang. [outletId] = gerai tempat order disimpan
/// (Batch C4) — baris lama memakai outlet utama (...0001).
class HeldOrders extends Table {
  TextColumn get id => text()();
  TextColumn get label => text()();
  TextColumn get itemsJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get outletId => text().withDefault(
        const Constant('00000000-0000-0000-0000-000000000001'),
      )();

  @override
  Set<Column> get primaryKey => {id};
}

/// Topping yang bisa dipilih di sheet opsi produk (Batch C1).
/// Nama topping HARUS sama dengan nama bahan stok (Boba/Jelly/dll) —
/// ToppingService menjaga sinkronisasinya. [active] = false berarti
/// topping disembunyikan dari sheet (tidak dihapus).
class Toppings extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get priceDelta => integer()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Gerai/outlet lokal (Batch C4 multi-gerai). Cermin lokal tabel
/// Supabase `outlets` — anon TIDAK bisa membaca tabel itu (RLS
/// member-only, butuh Supabase Auth M0), jadi daftar gerai yang
/// dipakai app adalah tabel ini (seed 4 gerai placeholder; Owner
/// ubah nama/alamat dari menu Gerai). [id] = UUID Supabase gerai itu
/// (...0001–...0004 untuk 4 gerai awal, SAMA dengan migrasi 006,
/// supaya sinkronisasi nanti tinggal cocokkan id); gerai baru yang
/// dibuat dari app memakai id 'local-<microseconds>' sampai ada
/// sinkronisasi ke Supabase.
class Outlets extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get address => text().withDefault(const Constant(''))();
  BoolColumn get isOpen => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Sesi kasir persisten (Batch C5): satu baris id 'current' — outlet
/// + nama kasir yang terakhir masuk. Buka app lagi = langsung masuk
/// gerai itu tanpa login ulang. Sesi Owner TIDAK PERNAH disimpan.
/// Keluar gerai = hapus baris ini.
/// [cashierId] = UUID kasir dari server (Batch C8.2) — null untuk
/// sesi lama (sebelum C8.2) yang hanya menyimpan nama.
class CashierSessions extends Table {
  TextColumn get id => text()();
  TextColumn get outletId => text()();
  TextColumn get cashierId => text().nullable()();
  TextColumn get cashierName => text()();
  DateTimeColumn get savedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Pengeluaran (Batch C7): satu baris per pengeluaran yang dicatat
/// kasir/Owner. [id] = client_uuid (UUID v4) — kunci idempotency
/// sync ke Supabase (kolom expenses.client_uuid, migrasi 009).
/// [isCash] = true berarti keluar dari laci tunai (mengurangi
/// expected tutup kas); false = non-tunai (tidak sentuh laci).
/// [amount] > 0 (CHECK di Supabase expenses.amount > 0).
/// Hapus = baris lokal dihapus + event 'expense' is_deleted=true
/// (server hapus by client_uuid) — lihat ExpenseService.
class Expenses extends Table {
  TextColumn get id => text()();
  TextColumn get outletId => text()();
  TextColumn get category => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  IntColumn get amount => integer()();
  BoolColumn get isCash => boolean().withDefault(const Constant(true))();
  TextColumn get cashierName => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Shift kas (Batch C7): satu baris per shift buka s.d. tutup.
/// [id] = client_uuid (UUID v4) — kunci idempotency sync ke
/// Supabase (cash_shifts.client_uuid, migrasi 009; upsert
/// last-write-wins: event buka lalu event tutup menimpa baris yang
/// sama). MAKSIMAL 1 shift 'open' per outlet (dijaga
/// CashShiftService — Batch C8.2 WS6: laci HANYA SATU, 2 kasir
/// berbagi 1 shift). [difference] = counted − expected (boleh
/// negatif = kurang). [closedAt]/[countedCash]/[expectedCash]/
/// [difference] null selama shift masih open.
/// [cashierId]/[cashierName] = kasir PEMBUKA (Batch C8.2 WS4/WS6 —
/// tampil di kartu "Kas & Shift"); [closedByCashierId]/
/// [closedByCashierName] = kasir/Owner PENUTUP (audit — siapa yang
/// menutup). Baris lama = '' (tampil 'Kasir' bila kosong).
class CashShifts extends Table {
  TextColumn get id => text()();
  TextColumn get outletId => text()();
  TextColumn get cashierId => text().nullable()();
  TextColumn get cashierName => text()();
  TextColumn get closedByCashierId => text().nullable()();
  TextColumn get closedByCashierName =>
      text().withDefault(const Constant(''))();
  DateTimeColumn get openedAt => dateTime()();
  IntColumn get openingFloat => integer()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  IntColumn get countedCash => integer().nullable()();
  IntColumn get expectedCash => integer().nullable()();
  IntColumn get difference => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  TextColumn get note => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Paket kiriman stok (Batch C10 WS2): paket bahan yang Owner
/// kirim ke gerai (mis. "Paket Standar Harian"). [id] = client_uuid
/// (UUID v4) — kunci idempotency sync master-data. [isActive] =
/// false berarti paket dihapus Owner (nonaktif + is_deleted di
/// server — baris TIDAK pernah dihapus fisik dari history).
class Packages extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Satu baris isi paket kiriman (Batch C10 WS2): [qty] > 0 dalam
/// [unit] = satuan baku bahan itu (terkunci di UI — tidak bisa
/// beda dari satuan bahan). Satu bahan max 1x per paket.
@DataClassName('DbPackageItem')
class PackageItems extends Table {
  TextColumn get id => text()();
  TextColumn get packageId => text()();
  TextColumn get stockName => text()();
  RealColumn get qty => real()();
  TextColumn get unit => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Paket default per gerai (Batch C10 WS2): satu paket per gerai
/// (nullable = gerai belum punya paket default). [updatedAt] UTC
/// untuk last-write-wins sync master-data.
class OutletPackageDefaults extends Table {
  TextColumn get outletId => text()();
  TextColumn get packageId => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {outletId};
}

/// Kiriman stok ke gerai (Batch C10 WS3): satu baris per pengiriman.
/// [packageId] null = kirim custom / top-up tanpa paket.
/// [packageName] = snapshot nama paket saat kirim (paket bisa
/// diganti nama sesudahnya). [status] 'ok' | 'gagal' — 'gagal'
/// = server menolak (gudang kurang) lalu kiriman dibalik lokal.
@DataClassName('DbStockSend')
class StockSends extends Table {
  TextColumn get id => text()();
  TextColumn get outletId => text()();
  TextColumn get packageId => text().nullable()();
  TextColumn get packageName => text().withDefault(const Constant(''))();
  DateTimeColumn get sentAt => dateTime()();
  TextColumn get sentBy => text().withDefault(const Constant('Owner'))();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('ok'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Isi satu kiriman (Batch C10 WS3): [qty] dalam [unit] baku bahan.
@DataClassName('DbSendItem')
class SendItems extends Table {
  TextColumn get id => text()();
  TextColumn get sendId => text()();
  TextColumn get stockName => text()();
  RealColumn get qty => real()();
  TextColumn get unit => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Opname stok (Batch C10 WS6): satu baris per bahan yang DIHITUNG
/// (bukan per sesi — satu opname bisa punya banyak baris).
/// [systemQty] = snapshot stok sistem saat hitung; [physicalQty] =
/// hasil hitung fisik; selisih = fisik − sistem (dihitung, tidak
/// disimpan). [adjusted] = true bila Owner sudah menekan
/// "Sesuaikan stok" untuk baris ini (stok sistem diubah = selisih).
@DataClassName('DbStockOpname')
class StockOpnames extends Table {
  TextColumn get id => text()();
  TextColumn get outletId => text()();
  TextColumn get stockName => text()();
  RealColumn get systemQty => real()();
  RealColumn get physicalQty => real()();
  DateTimeColumn get countedAt => dateTime()();
  TextColumn get countedBy => text().withDefault(const Constant('Owner'))();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get adjusted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Target omzet harian per gerai (Batch C10 WS7 §4): [targetOmzet]
/// rupiah per hari, 0 = belum ada target. [updatedAt] UTC untuk
/// last-write-wins sync master-data.
@DataClassName('DbGeraiTarget')
class GeraiTargets extends Table {
  TextColumn get outletId => text()();
  IntColumn get targetOmzet => integer()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {outletId};
}

/// Riwayat stok masuk gudang (Batch C10 WS1): satu baris per
/// pencatatan masuk. [totalPrice] = harga beli TOTAL (Rp, 0 =
/// tidak diisi — costPerUnit bahan tidak berubah bila 0).
/// [date] = tanggal masuk (default hari ini, maks 30 hari mundur,
/// tidak pernah masa depan). TIDAK ada edit/hapus riwayat (audit
/// trail — salah catat diperbaiki via Opname + penyesuaian).
class StockIns extends Table {
  TextColumn get id => text()();
  TextColumn get stockName => text()();
  TextColumn get unit => text()();
  RealColumn get qty => real()();
  IntColumn get totalPrice => integer().withDefault(const Constant(0))();
  TextColumn get supplier => text().withDefault(const Constant(''))();
  DateTimeColumn get date => dateTime()();
  TextColumn get note => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Riwayat masak teh (Batch C10 WS4): satu baris per aksi Masak Teh.
/// [kgUsed] = Teh Kering dipakai (kg); [litersMade] = Teh Masak
/// dihasilkan (liter) — TIDAK ada rasio asumsi, keduanya angka
/// nyata dari yang masak. Kedaluwarsa (sisa kemarin terbuang)
/// dicatat sebagai mutasi stok reason 'kedaluwarsa', bukan baris
/// di sini (lihat riwayat masak di BrewService — gabungan tabel
/// ini + mutasi 'kedaluwarsa' dari pull).
@DataClassName('DbBrewRecord')
class BrewRecords extends Table {
  TextColumn get id => text()();
  TextColumn get outletId => text()();
  RealColumn get kgUsed => real()();
  RealColumn get litersMade => real()();
  DateTimeColumn get brewedAt => dateTime()();
  TextColumn get brewedBy => text().withDefault(const Constant('Owner'))();
  RealColumn get expiredLiters => real().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Status masak per gerai (Batch C10 WS4): tanggal TERAKHIR Teh
/// Masak dimasak di gerai itu. Bila [brewedDate] < hari ini dan
/// Teh Masak masih bersisa, sisa itu hangus (kedaluwarsa) saat
/// app start / tiap tick 10 detik / sebelum penjualan.
/// [litersMade] = total liter Teh Masak hari itu (dipakai hitung
/// biaya tertimbang + label sisa di UI; saldo sendiri di StockLevels).
@DataClassName('DbBrewState')
class BrewStates extends Table {
  TextColumn get outletId => text()();
  DateTimeColumn get brewedDate => dateTime().nullable()();
  RealColumn get litersMade => real().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {outletId};
}

@DriftDatabase(tables: [
  OutboxEntries,
  LocalProducts,
  StockLevels,
  ProductRecipes,
  SaleHistory,
  HeldOrders,
  Toppings,
  Outlets,
  CashierSessions,
  Expenses,
  CashShifts,
  Packages,
  PackageItems,
  OutletPackageDefaults,
  StockSends,
  SendItems,
  StockOpnames,
  GeraiTargets,
  StockIns,
  BrewRecords,
  BrewStates,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'suka-tea'));

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          // v1 -> v2 (22 Nov 2026): tambah tabel stok + resep.
          // Tabel lama (OutboxEntries, LocalProducts) TIDAK dihapus.
          if (from < 2) {
            await m.createTable(stockLevels);
            await m.createTable(productRecipes);
          }
          // v2 -> v3 (22 Nov 2026): tambah tabel riwayat penjualan.
          // Tabel lama TIDAK dihapus.
          if (from < 3) {
            await m.createTable(saleHistory);
          }
          // v3 -> v4 (23 Nov 2026, Batch C1): tambah kolom diskon +
          // void di SaleHistory, dan tabel baru HeldOrders + Toppings.
          // Tabel lama TIDAK dihapus.
          if (from < 4) {
            await m.addColumn(saleHistory, saleHistory.discount);
            await m.addColumn(saleHistory, saleHistory.isVoid);
            await m.createTable(heldOrders);
            await m.createTable(toppings);
          }
          // v4 -> v5 (23 Nov 2026, Batch C1b): tambah kolom harga bahan
          // per satuan di StockLevels (Owner yang menentukan, bukan
          // estimasi). Default 0 — backfill nilai awal dari
          // seedStockCostPerUnit jalan di StockService.init().
          // Tabel lama TIDAK dihapus.
          if (from < 5) {
            await m.addColumn(stockLevels, stockLevels.costPerUnit);
          }
          // v5 -> v6 (23 Nov 2026, Batch C4 multi-gerai): tabel Outlets
          // + kolom outletId di SaleHistory + HeldOrders (transaksi &
          // order Pending tercatat per gerai). Baris lama memakai
          // outlet utama (...0001) lewat default kolom.
          // Tabel lama TIDAK dihapus.
          if (from < 6) {
            await m.createTable(outlets);
            await m.addColumn(saleHistory, saleHistory.outletId);
            await m.addColumn(heldOrders, heldOrders.outletId);
          }
          // v6 -> v7 (23 Nov 2026, Batch C2 split payment): kolom
          // bagian QRIS + tunai di SaleHistory. Baris lama = 0
          // (bukan split). Tabel lama TIDAK dihapus.
          if (from < 7) {
            await m.addColumn(saleHistory, saleHistory.qrisAmount);
            await m.addColumn(saleHistory, saleHistory.cashAmount);
          }
          // v7 -> v8 (23 Nov 2026, Batch C5 sesi kasir): tabel baru
          // CashierSessions (satu baris id 'current'). Tabel lama
          // TIDAK dihapus.
          if (from < 8) {
            await m.createTable(cashierSessions);
          }
          // v8 -> v9 (24 Nov 2026, Batch C7 tutup kas + pengeluaran):
          // tabel baru Expenses + CashShifts. Tabel lama TIDAK
          // dihapus.
          if (from < 9) {
            await m.createTable(expenses);
            await m.createTable(cashShifts);
          }
          // v9 -> v10 (24 Nov 2026, Batch C8.2):
          // - SaleHistory + cashierId/cashierName (WS4 — kasir
          //   pencatat per penjualan).
          // - CashierSessions + cashierId (WS3 — identitas kasir
          //   dari server, nullable: sesi lama hanya punya nama).
          // - CashShifts + cashierId (pembuka) + closedByCashierId/
          //   closedByCashierName (penutup, audit WS6).
          // - StockLevels REBUILD: PK {name} -> {outletId, name}
          //   (WS5 — stok per gerai). Baris lama dipindah ke outlet
          //   utama (...0001) — sebelum C8.2 semua stok memang
          //   milik gerai itu (hardcode). Tabel lama TIDAK dihapus,
          //   kecuali stock_levels_old (salinan sementara rebuild).
          if (from < 10) {
            await m.addColumn(saleHistory, saleHistory.cashierId);
            await m.addColumn(saleHistory, saleHistory.cashierName);
            await m.addColumn(cashierSessions, cashierSessions.cashierId);
            await m.addColumn(cashShifts, cashShifts.cashierId);
            await m.addColumn(
              cashShifts,
              cashShifts.closedByCashierId,
            );
            await m.addColumn(
              cashShifts,
              cashShifts.closedByCashierName,
            );
            await m.database.customStatement(
              'ALTER TABLE stock_levels RENAME TO stock_levels_old',
            );
            await m.createTable(stockLevels);
            await m.database.customStatement(
              'INSERT INTO stock_levels '
              '(outlet_id, name, unit, qty, low_threshold, cost_per_unit) '
              "SELECT '00000000-0000-0000-0000-000000000001', "
              'name, unit, qty, low_threshold, cost_per_unit '
              'FROM stock_levels_old',
            );
            await m.database.customStatement('DROP TABLE stock_levels_old');
          }
          // v10 -> v11 (24 Nov 2026, Batch C10 stok + gudang):
          // - StockLevels + shelfLifeDays (Teh Masak = 1 hari).
          // - Tabel baru: Packages, PackageItems,
          //   OutletPackageDefaults, StockSends, SendItems,
          //   StockOpnames, GeraiTargets, StockIns, BrewRecords,
          //   BrewStates.
          // - 'Teh' (kg, daun kering) DIGANTI NAMA jadi 'Teh Kering'
          //   di semua gerai — resep 22oz yang memakai 'Teh'
          //   diganti 'Teh Masak' 0.4 liter/cup; baris resep _r/_j
          //   LAMA SENGAJA TIDAK disentuh (void-restore penjualan
          //   lama tetap menemukan resepnya).
          // - Tiap gerai yang punya 'Teh Kering' mendapat baris
          //   'Teh Masak' (liter, 0, shelfLifeDays 1) bila belum ada.
          if (from < 11) {
            await m.addColumn(stockLevels, stockLevels.shelfLifeDays);
            await m.createTable(packages);
            await m.createTable(packageItems);
            await m.createTable(outletPackageDefaults);
            await m.createTable(stockSends);
            await m.createTable(sendItems);
            await m.createTable(stockOpnames);
            await m.createTable(geraiTargets);
            await m.createTable(stockIns);
            await m.createTable(brewRecords);
            await m.createTable(brewStates);
            await m.database.customStatement(
              "UPDATE stock_levels SET name = 'Teh Kering' "
              "WHERE name = 'Teh'",
            );
            await m.database.customStatement(
              "UPDATE product_recipes SET stock_name = 'Teh Masak', "
              "qty = 0.4 WHERE stock_name = 'Teh' "
              "AND variant_id GLOB '*_22oz'",
            );
            await m.database.customStatement(
              'INSERT OR IGNORE INTO stock_levels '
              '(outlet_id, name, unit, qty, low_threshold, '
              'cost_per_unit, shelf_life_days) '
              "SELECT outlet_id, 'Teh Masak', 'liter', 0, 0, 0, 1 "
              "FROM stock_levels WHERE name = 'Teh Kering'",
            );
          }
        },
      );

  Future<List<OutboxEntry>> pendingEntries() {
    return (select(outboxEntries)
          ..where((t) => t.status.equals('pending'))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  Future<void> markSent(String id) async {
    await (update(outboxEntries)..where((t) => t.id.equals(id)))
        .write(const OutboxEntriesCompanion(status: Value('sent')));
  }

  /// Hapus entri outbox yang dibuang — dipakai CashShiftService saat
  /// mengadopsi shift server (duplikat lokal yang kalah dedupe:
  /// event buka + tutup-nya tidak boleh terkirim lagi).
  Future<void> deleteOutboxEntries(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await (delete(outboxEntries)..where((t) => t.id.isIn(list))).go();
  }
}
