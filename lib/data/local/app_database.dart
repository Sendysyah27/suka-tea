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

@DriftDatabase(tables: [OutboxEntries, LocalProducts])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'suka-tea'));

  @override
  int get schemaVersion => 1;

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
