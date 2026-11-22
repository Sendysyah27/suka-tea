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
class StockLevels extends Table {
  TextColumn get name => text()();
  TextColumn get unit => text()();
  RealColumn get qty => real()();
  RealColumn get lowThreshold => real()();

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
class SaleHistory extends Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get itemsJson => text()();
  IntColumn get total => integer()();
  TextColumn get method => text()();
  IntColumn get paid => integer()();
  IntColumn get change => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [
  OutboxEntries,
  LocalProducts,
  StockLevels,
  ProductRecipes,
  SaleHistory,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'suka-tea'));

  @override
  int get schemaVersion => 3;

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
