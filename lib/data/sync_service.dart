import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'outlet_service.dart';
import 'sale_history.dart';
import 'supabase_client.dart';
import 'sync_payload.dart';

/// Transport ke Edge Function `sync-sales`: menerima body request,
/// mengembalikan Map jawaban (sudah diparse). Transport default
/// memakai functions.invoke; test menyuntikkan transport palsu.
typedef SyncTransport = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> body,
);

/// Hasil satu flush: id outbox yang boleh ditandai terkirim + yang gagal.
typedef FlushResult = ({
  List<String> sentIds,
  List<String> failedIds,
  List<String> skippedIds,
});

/// Flush murni (tanpa Drift): ubah antrean pending jadi event, kirim
/// sekali jalan via [transport], kembalikan id yang boleh ditandai
/// terkirim + yang gagal. Dipisah dari SyncService supaya bisa
/// di-test tanpa database.
///
/// - Entri yang payload-nya tidak valid dilewati (masuk failed, TIDAK
///   memblokir entri lain) — payload rusak tidak sembuh dengan retry.
/// - Mutasi stok LAMA (pra-C6, bentuk deductions/additions) dilewati
///   dengan sengaja (masuk skipped, lalu ditandai terkirim oleh
///   pemanggil): bentuk itu tidak bisa direkonstruksi jadi level
///   absolut; level stok Supabase pulih dari mutasi baru pertama.
/// - Transport throw / jawaban rusak = SEMUA event dianggap gagal
///   (jangan tandai terkirim tanpa konfirmasi server).
/// - Urutan pengiriman = urutan createdAt antrean (FIFO) — penting
///   supaya event void tidak tertukar dengan penjualan asalnya, dan
///   event hapus pengeluaran / tutup shift selalu sesudah event
///   tambah / buka baris yang sama.
Future<FlushResult> flushOutboxEntries(
  List<OutboxEntry> pending,
  SyncTransport transport,
) async {
  final events = <Map<String, dynamic>>[];
  final failed = <String>[];
  final skipped = <String>[];
  for (final entry in pending) {
    try {
      final raw = jsonDecode(entry.payload);
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('payload bukan Map<String, dynamic>');
      }
      if (entry.kind == 'stock_movement' && isLegacyStockPayload(raw)) {
        debugPrint(
          'Sync: antrean ${entry.id} dilewati (mutasi stok lama pra-C6).',
        );
        skipped.add(entry.id);
        continue;
      }
      events.add(_normalizeEntry(entry, raw));
    } catch (e) {
      debugPrint('Sync: antrean ${entry.id} dilewati (payload tidak '
          'valid): $e');
      failed.add(entry.id);
    }
  }
  if (events.isEmpty) {
    return (
      sentIds: const <String>[],
      failedIds: failed,
      skippedIds: skipped,
    );
  }
  try {
    final res = await transport({'action': 'push', 'events': events});
    final outcome = applyPushResults(events, res, failed);
    return (
      sentIds: outcome.sentIds,
      failedIds: outcome.failedIds,
      skippedIds: skipped,
    );
  } catch (e) {
    debugPrint('Sync push gagal (transport): $e');
    return (
      sentIds: const <String>[],
      failedIds: [
        ...failed,
        ...events.map((e) => e['outbox_id'] as String),
      ],
      skippedIds: skipped,
    );
  }
}

/// Pilih normalizer per kind antrean. Kind tak dikenal jatuh ke
/// [normalizeSaleEvent] (perilaku lama C6) — normalizer itu throw
/// karena field penjualan tidak ada, jadi entri masuk failed tanpa
/// memblokir antrean lain.
Map<String, dynamic> _normalizeEntry(
  OutboxEntry entry,
  Map<String, dynamic> raw,
) {
  if (entry.kind == 'stock_movement') {
    return normalizeStockEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
      fallbackOutletId: defaultOutletId,
    );
  }
  if (entry.kind == 'expense') {
    return normalizeExpenseEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
      fallbackOutletId: defaultOutletId,
    );
  }
  if (entry.kind == 'shift') {
    return normalizeShiftEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
      fallbackOutletId: defaultOutletId,
    );
  }
  return normalizeSaleEvent(
    outboxId: entry.id,
    rawPayload: raw,
    entryCreatedAt: entry.createdAt,
    fallbackOutletId: defaultOutletId,
  );
}

/// Sinkronisasi Supabase per-gerai (Batch C6).
///
/// - Jualan TIDAK PERNAH diblokir sync: penjualan tetap jalan offline,
///   sync fire-and-forget di background; gagal = tetap pending, coba
///   lagi nanti (pemicu: sesudah penjualan/void + saat app start +
///   retry berkala 60 dtk selama masih ada pending).
/// - Entri ditandai terkirim HANYA sesudah server konfirmasi per-event
///   (results[].ok) — bukan sesudah request terkirim.
/// - Tanpa Supabase terkonfigurasi, semua sync dilewati diam-diam
///   (mode offline) tapi hitungan pending tetap diperbarui untuk UI.
class SyncService extends ChangeNotifier {
  SyncService._({SyncTransport? transport, OutboxService? outbox})
      : _transport = transport ?? _defaultTransport,
        _outbox = outbox ?? OutboxService.instance;

  static final SyncService instance = SyncService._();

  /// Instance terpisah buat test (transport palsu, tanpa Supabase).
  static SyncService createForTest({
    required SyncTransport transport,
    OutboxService? outbox,
  }) =>
      SyncService._(transport: transport, outbox: outbox);

  final SyncTransport _transport;
  final OutboxService _outbox;

  Timer? _timer;
  bool _syncing = false;
  int _pendingCount = 0;
  DateTime? _lastSyncAt;
  String? _lastError;

  bool get isConfigured => SupabaseService.instance.isConfigured;
  bool get isSyncing => _syncing;

  /// Jumlah antrean belum terkirim (cache lokal — untuk indikator UI).
  int get pendingCount => _pendingCount;

  DateTime? get lastSyncAt => _lastSyncAt;
  String? get lastError => _lastError;

  static Future<Map<String, dynamic>> _defaultTransport(
    Map<String, dynamic> body,
  ) async {
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'sync-sales',
        body: body,
      );
      final data = res.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const FormatException('jawaban sync-sales tidak dikenal');
    } on FunctionException catch (e) {
      // Edge Function mengembalikan 4xx/5xx dengan body JSON {ok, error}:
      // details membawa body itu. NAMA KELAS: `FunctionException`
      // (tunggal) — supabase_flutter 2.x. JANGAN "diperbaiki" ke
      // `FunctionsException` (itu 3.x — ketangkep CI v28).
      final details = e.details;
      if (details is Map<String, dynamic>) return details;
      if (details is Map) return Map<String, dynamic>.from(details);
      throw StateError('sync-sales ${e.status}: ${e.reasonPhrase}');
    }
  }

  /// Perbarui hitungan pending dari Drift (untuk indikator UI).
  Future<void> refreshPending() async {
    _pendingCount = await _outbox.pendingCount();
    notifyListeners();
  }

  /// Mulai sync: sekali jalan saat app start + retry berkala tiap
  /// 60 dtk. Aman dipanggil berkali-kali (timer hanya dibuat sekali).
  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(syncNow()),
    );
    unawaited(syncNow());
  }

  /// Hentikan timer berkala (dipakai test).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Kirim semua antrean pending sekarang. No-op bila sedang sync
  /// atau Supabase belum dikonfigurasi. Tidak pernah throw.
  Future<void> syncNow() async {
    if (_syncing) return;
    if (!isConfigured) {
      await refreshPending();
      return;
    }
    _syncing = true;
    try {
      final pending = await _outbox.pendingEntries();
      if (pending.isEmpty) {
        _pendingCount = 0;
        _lastError = null;
        notifyListeners();
        return;
      }
      final result = await flushOutboxEntries(pending, _transport);
      for (final id in result.sentIds) {
        await _outbox.markSent(id);
      }
      // Dilewati dengan sengaja (mutasi stok lama pra-C6 — lihat
      // flushOutboxEntries): bukan gagal, jadi ikut ditandai terkirim
      // supaya tidak nyangkut pending selamanya.
      for (final id in result.skippedIds) {
        await _outbox.markSent(id);
      }
      for (final id in result.failedIds) {
        await _outbox.incrementAttempts(id);
      }
      _lastSyncAt = DateTime.now();
      _lastError = result.failedIds.isEmpty
          ? null
          : '${result.failedIds.length} antrean belum terkirim — coba lagi nanti.';
      await refreshPending();
    } catch (e) {
      debugPrint('Sync gagal: $e');
      _lastError = 'Sinkronisasi gagal — coba lagi nanti.';
      notifyListeners();
    } finally {
      _syncing = false;
    }
  }

  /// Baca transaksi gerai dari Supabase (jalur Owner — live dari
  /// mana aja). [from]/[to] inklusif tanggal (zona lokal); server
  /// memotong hari dalam WIB. Throw bila Supabase belum
  /// dikonfigurasi / jawaban server tidak valid.
  Future<List<SaleRecord>> pullOutlet({
    required String outletId,
    required DateTime from,
    required DateTime to,
  }) async {
    if (!isConfigured) {
      throw StateError('Supabase belum dikonfigurasi.');
    }
    final res = await _transport({
      'action': 'pull',
      'outlet_id': outletId,
      'from': dateOnly(from),
      'to': dateOnly(to),
    });
    final parsed = parsePullResponse(res);
    return parsed.transactions
        .map(
          (t) => SaleRecord.fromServer(
            t,
            parsed.itemsByClientUuid[t['client_uuid'] as String? ?? ''] ??
                const <Map<String, dynamic>>[],
          ),
        )
        .toList();
  }
}
