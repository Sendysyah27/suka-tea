import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'cash_shift_service.dart';
import 'models.dart';
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
/// [shiftAdoptions] = event shift yang kena dedupe server (Batch
/// C8.2 WS6) — event-nya tetap terkirim, tapi app harus mengadopsi
/// shift server itu (localClientUuid terisi dari event yang dikirim).
typedef FlushResult = ({
  List<String> sentIds,
  List<String> failedIds,
  List<String> skippedIds,
  List<ShiftAdoption> shiftAdoptions,
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
      shiftAdoptions: const <ShiftAdoption>[],
    );
  }
  try {
    final res = await transport({'action': 'push', 'events': events});
    final outcome = applyPushResults(events, res, failed);
    // Adopsi dedupe butuh client_uuid lokal event shift yang ditolak
    // (id shift lokal) — ambil dari event yang dikirim (server tidak
    // mengirimnya kembali).
    final byOutboxId = <String, Map<String, dynamic>>{
      for (final e in events) e['outbox_id'] as String: e,
    };
    final adoptions = outcome.shiftAdoptions.map((a) {
      final event = byOutboxId[a.outboxId];
      final localUuid = event?['client_uuid'];
      return (
        outboxId: a.outboxId,
        existingClientUuid: a.existingClientUuid,
        existingOpenedAt: a.existingOpenedAt,
        existingCashierName: a.existingCashierName,
        existingCashierId: a.existingCashierId,
        existingOpeningFloat: a.existingOpeningFloat,
        localClientUuid: localUuid is String ? localUuid : '',
      );
    }).toList();
    return (
      sentIds: outcome.sentIds,
      failedIds: outcome.failedIds,
      skippedIds: skipped,
      shiftAdoptions: adoptions,
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
      shiftAdoptions: const <ShiftAdoption>[],
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
/// - Batch C8.2 WS6: timer berkala juga menarik shift terbuka gerai
///   ini ([refreshShifts]) supaya gate POS di device lain tahu shift
///   sudah dibuka; push shift yang kalah dedupe server diadopsi
///   (lihat CashShiftService.adoptServerShift).
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
  /// Timer juga menarik shift terbuka gerai ini (Batch C8.2 WS6)
  /// supaya gate POS tahu shift sudah dibuka di device lain.
  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        unawaited(syncNow());
        unawaited(refreshShifts());
      },
    );
    unawaited(syncNow());
    unawaited(refreshShifts());
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
      // Dedupe shift (Batch C8.2 WS6): event buka lokal ditolak
      // server karena shift lain lebih awal — adopsi shift server
      // itu, buang duplikat lokalnya. Gagal adopsi tidak menggagalkan
      // sync (coba lagi di pull berikutnya).
      for (final adoption in result.shiftAdoptions) {
        try {
          await CashShiftService.instance.adoptServerShift(adoption);
        } catch (e) {
          debugPrint('Adopsi shift server gagal: $e');
        }
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

  /// Baca transaksi + stok + shift terbuka gerai dari Supabase
  /// (jalur Owner — live dari mana aja). [from]/[to] inklusif
  /// tanggal (zona lokal) untuk transaksi; server memotong hari
  /// dalam WIB. Stok = level gerai yang diminta (Batch C8.2 WS5);
  /// shift = shift TERBUKA gerai itu (Batch C8.2 WS6, untuk gate
  /// POS antar device). Throw bila Supabase belum dikonfigurasi /
  /// jawaban server tidak valid.
  Future<({
    List<SaleRecord> sales,
    List<StockItem> stock,
    List<ShiftSummary> shifts,
  })> pullOutlet({
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
    final sales = parsed.transactions
        .map(
          (t) => SaleRecord.fromServer(
            t,
            parsed.itemsByClientUuid[t['client_uuid'] as String? ?? ''] ??
                const <Map<String, dynamic>>[],
          ),
        )
        .toList();
    final stock = parsed.stock
        .map(
          (s) => StockItem(
            name: s['name'] as String? ?? '',
            unit: s['unit'] as String? ?? 'pcs',
            qty: (s['qty'] as num? ?? 0).toDouble(),
            lowThreshold: (s['low_threshold'] as num? ?? 0).toDouble(),
            costPerUnit: (s['cost_per_unit'] as num? ?? -1).toDouble(),
            outletId: outletId,
          ),
        )
        .toList();
    return (sales: sales, stock: stock, shifts: parsed.shifts);
  }

  /// Tarik shift terbuka gerai ini dari server + adopsi bila perlu
  /// (Batch C8.2 WS6 — visibilitas antar device). Dipanggil saat
  /// login/app start + berkala tiap 60 dtk (lihat start()). No-op
  /// bila offline / gagal (gate memakai data lokal terakhir).
  /// Tidak pernah throw.
  Future<void> refreshShifts({String? outletId}) async {
    if (!isConfigured) return;
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    try {
      final now = DateTime.now();
      final pulled = await pullOutlet(
        outletId: outlet,
        from: now.subtract(const Duration(days: 30)),
        to: now,
      );
      await CashShiftService.instance.applyPulledShifts(
        outletId: outlet,
        serverOpens: pulled.shifts,
      );
    } catch (e) {
      debugPrint('Refresh shift gagal: $e');
    }
  }

  /// Expected kas dari SERVER (Batch C8.2 WS6): cash_in (semua
  /// transaksi tunai gerai itu di [from, to)) dikurangi cash_out
  /// (pengeluaran tunai gerai itu di jendela yang sama). Pemanggil
  /// menambahkan opening_float shift itu sendiri. null = offline /
  /// gagal — pemanggil memakai hitungan lokal berlabel
  /// "perkiraan (offline)". Tidak pernah throw.
  Future<({int cashIn, int cashOut})?> fetchShiftExpected({
    required String outletId,
    required DateTime from,
    required DateTime to,
  }) async {
    if (!isConfigured) return null;
    try {
      final res = await _transport({
        'action': 'shift_expected',
        'outlet_id': outletId,
        'from': from.toIso8601String(),
        'to': to.toIso8601String(),
      });
      return parseShiftExpectedResponse(res);
    } catch (e) {
      debugPrint('Expected server gagal: $e');
      return null;
    }
  }
}
