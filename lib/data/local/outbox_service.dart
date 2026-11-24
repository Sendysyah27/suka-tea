import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'app_database.dart';

/// Antrean pengiriman offline. Semua penulisan dibungkus try/catch supaya
/// kasir tidak pernah gagal hanya karena database lokal bermasalah.
class OutboxService {
  OutboxService._();

  static final OutboxService instance = OutboxService._();

  AppDatabase? _db;

  AppDatabase get _database => _db ??= AppDatabase();

  /// Simpan satu transaksi ke outbox. Mengembalikan id antrean.
  /// [kind] default 'transaction'; mutasi stok memakai 'stock_movement'.
  Future<String> enqueueSale(
    Map<String, Object?> payload, {
    String kind = 'transaction',
  }) async {
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${payload.hashCode}';
    try {
      await _database.into(_database.outboxEntries).insert(
            OutboxEntriesCompanion.insert(
              id: id,
              kind: kind,
              payload: jsonEncode(payload),
            ),
          );
    } catch (e) {
      debugPrint('Outbox enqueue gagal (transaksi tetap dicatat di memori): $e');
    }
    return id;
  }

  /// Jumlah antrean yang belum terkirim (untuk indikator sync di UI).
  Future<int> pendingCount() async {
    try {
      final rows = await _database.pendingEntries();
      return rows.length;
    } catch (_) {
      return 0;
    }
  }

  /// Antrean yang belum terkirim (untuk SyncService — flush).
  Future<List<OutboxEntry>> pendingEntries() async {
    try {
      return await _database.pendingEntries();
    } catch (_) {
      return [];
    }
  }

  /// Tandai satu entri sebagai terkirim. HANYA dipanggil SyncService
  /// sesudah server konfirmasi per-event (results[].ok) — bukan
  /// sesudah request terkirim.
  Future<void> markSent(String id) async {
    try {
      await _database.markSent(id);
    } catch (e) {
      debugPrint('Outbox markSent gagal: $e');
    }
  }

  /// Tambah hitungan percobaan kirim satu entri (gagal sync).
  /// Entri TETAP pending — hanya dicatat supaya terlihat bila
  /// sebuah entri macet berulang. Tidak pernah menghapus antrean.
  Future<void> incrementAttempts(String id) async {
    try {
      final row = await (_database.select(_database.outboxEntries)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (row == null) return;
      await (_database.update(_database.outboxEntries)
            ..where((t) => t.id.equals(id)))
          .write(
            OutboxEntriesCompanion(attempts: Value(row.attempts + 1)),
          );
    } catch (e) {
      debugPrint('Outbox incrementAttempts gagal: $e');
    }
  }
}
