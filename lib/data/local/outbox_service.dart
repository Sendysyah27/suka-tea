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
  Future<String> enqueueSale(Map<String, Object?> payload) async {
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${payload.hashCode}';
    try {
      await _database.into(_database.outboxEntries).insert(
            OutboxEntriesCompanion.insert(
              id: id,
              kind: 'transaction',
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

  // TODO (M3): syncPending() — kirim antrean ke Supabase dengan
  // client_uuid sebagai kunci idempotency, lalu markSent per baris.
}
