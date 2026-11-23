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
/// Satu baris per nama bahan — nama adalah kunci.
/// [costPerUnit] = harga bahan per satuan (rupiah) — DITENTUKAN Owner
/// di tab Stok (Batch C1b). -1 = belum diatur (HPP bahan itu Rp0);
/// 0 = gratis (sengaja).
class StockLevels extends Table {
  TextColumn get name => text()();
  TextColumn get unit => text()();
  RealColumn get qty => real()();
  RealColumn get lowThreshold => real()();
  RealColumn get costPerUnit => real().withDefault(const Constant(-1))();

  @override
  Set<Column> get primaryKey => {name};
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

@DriftDatabase(tables: [
  OutboxEntries,
  LocalProducts,
  StockLevels,
  ProductRecipes,
  SaleHistory,
  HeldOrders,
  Toppings,
  Outlets,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'suka-tea'));

  @override
  int get schemaVersion => 7;

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
}
