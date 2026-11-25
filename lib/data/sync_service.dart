import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local/app_database.dart' hide Expense;
import 'local/outbox_service.dart';
import 'brew_service.dart';
import 'c10_models.dart';
import 'cash_shift_service.dart';
import 'expense_service.dart';
import 'master_sync.dart';
import 'menu_service.dart';
import 'models.dart';
import 'outlet_service.dart';
import 'package_service.dart';
import 'sale_history.dart';
import 'stock_service.dart';
import 'supabase_client.dart';
import '../features/login/cashier_session.dart';
import '../features/kasir/cashier_service.dart';
import 'sync_payload.dart';
import 'topping_service.dart';

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
/// [failedErrors] (Batch C10 WS3) = outbox_id -> error server
/// (mis. 'gudang_kurang') — dipakai SyncService untuk membalik
/// kiriman yang ditolak server.
/// [topReason] (v40) = `reason` jawaban top-level bila ok != true
/// (mis. 'kicked' / 'outlet_not_allowed') — dipakai SyncService
/// untuk mengunci sesi kasir yang dicabut Owner.
typedef FlushResult = ({
  List<String> sentIds,
  List<String> failedIds,
  List<String> skippedIds,
  List<ShiftAdoption> shiftAdoptions,
  Map<String, String> failedErrors,
  String? topReason,
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
  SyncTransport transport, {
  /// Bukti PIN sesi (SEC-1 R-02) — {'owner_pin': ...} atau
  /// {'cashier_pin': ...}. Kosong = body tanpa bukti (test lama).
  Map<String, dynamic> proof = const <String, dynamic>{},
}) async {
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
      failedErrors: const <String, String>{},
      topReason: null,
    );
  }
  try {
    final res = await transport({
      'action': 'push',
      'events': events,
      ...proof,
    });
    // v40: alasan top-level (kicked / outlet_not_allowed) diteruskan
    // ke pemanggil — bukti PIN ditolak server = sesi dicabut.
    final topReason = res['ok'] != true && res['reason'] is String
        ? res['reason'] as String
        : null;
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
      failedErrors: outcome.failedErrors,
      topReason: topReason,
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
      failedErrors: const <String, String>{},
      topReason: null,
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
  // Batch C10 — kind baru (lihat sync_payload.dart + C10-BRIEF §3).
  if (entry.kind == 'master') {
    return normalizeMasterEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
    );
  }
  if (entry.kind == 'stock_in') {
    return normalizeStockInEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
    );
  }
  if (entry.kind == 'brew') {
    return normalizeBrewEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
    );
  }
  if (entry.kind == 'stock_send') {
    return normalizeStockSendEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
    );
  }
  if (entry.kind == 'opname') {
    return normalizeOpnameEvent(
      outboxId: entry.id,
      rawPayload: raw,
      entryCreatedAt: entry.createdAt,
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
///   ini supaya gate POS di device lain tahu shift sudah dibuka;
///   push shift yang kalah dedupe server diadopsi (lihat
///   CashShiftService.adoptServerShift). Batch C9: [refreshShifts]
///   = alias [refreshSales] (pull lengkap).
/// - Batch C9: timer jadi 10 DETIK dan menarik SEMUA data gerai
///   ([refreshSales] — penjualan + pengeluaran + stok + shift
///   terbuka/tutup + mutasi) supaya HP lain melihat perubahan
///   dalam hitungan detik, bukan menit. Satu pull per tick
///   (guard [_pullingSales]).
class SyncService extends ChangeNotifier {
  SyncService._({
    SyncTransport? transport,
    OutboxService? outbox,
    bool? configured,
  })  : _transport = transport ?? _defaultTransport,
        _outbox = outbox ?? OutboxService.instance,
        _configuredOverride = configured;

  static final SyncService instance = SyncService._();

  /// Instance terpisah buat test (transport palsu, tanpa Supabase).
  /// [configured] = paksa [isConfigured] (test: Supabase tidak
  /// terkonfigurasi di test env, jadi tanpa seam ini refreshSales
  /// selalu no-op).
  static SyncService createForTest({
    required SyncTransport transport,
    OutboxService? outbox,
    bool? configured,
  }) =>
      SyncService._(
        transport: transport,
        outbox: outbox,
        configured: configured,
      );

  final SyncTransport _transport;
  final OutboxService _outbox;
  final bool? _configuredOverride;

  Timer? _timer;
  bool _syncing = false;
  bool _pullingSales = false;
  int _pendingCount = 0;
  DateTime? _lastSyncAt;
  DateTime? _lastPullAt;
  String? _lastError;

  /// Mutasi stok terakhir hasil pull + mutasi lokal pending (untuk
  /// riwayat keluar-masuk barang di tab Stok, Batch C9 WS6).
  /// Terbaru dulu. Kosong = belum pernah pull berhasil.
  List<StockMovement> _lastMovements = [];

  List<StockMovement> get lastMovements => List.unmodifiable(_lastMovements);

  /// Gerai yang SUDAH pernah berhasil pull (Batch C10 WS7):
  /// Dashboard menampilkan "Belum ada data tersinkron" untuk gerai
  /// yang belum pernah pull — JANGAN tampilkan angka 0 seolah data.
  /// Gudang (GUDANG_ID) dicatat terpisah — pull gudang hanya
  /// menarik stok gudang, bukan penjualan.
  final Set<String> _syncedOutlets = {};

  /// Gerai yang sudah pernah pull berhasil (salinan).
  Set<String> get syncedOutletIds => Set.unmodifiable(_syncedOutlets);

  /// true = gerai [outletId] sudah pernah pull berhasil.
  bool hasSynced(String outletId) => _syncedOutlets.contains(outletId);

  bool get isConfigured =>
      _configuredOverride ?? SupabaseService.instance.isConfigured;
  bool get isSyncing => _syncing;

  /// Jumlah antrean belum terkirim (cache lokal — untuk indikator UI).
  int get pendingCount => _pendingCount;

  DateTime? get lastSyncAt => _lastSyncAt;

  /// Waktu pull terakhir yang berhasil (null = belum pernah).
  DateTime? get lastPullAt => _lastPullAt;
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

  /// v40: alasan 'kicked' / 'outlet_not_allowed' dari server = sesi
  /// kasir ini sudah dicabut Owner → kunci HP (hapus sesi + notice
  /// untuk LoginPage). Satu-satunya tempat yang membaca reason
  /// top-level — jangan sebar cek ini ke tempat lain.
  void _checkKickReason(String? reason) {
    if (reason == 'kicked' || reason == 'outlet_not_allowed') {
      unawaited(CashierSessionService.instance.markKicked());
    }
  }

  /// Perbarui hitungan pending dari Drift (untuk indikator UI).
  Future<void> refreshPending() async {
    _pendingCount = await _outbox.pendingCount();
    notifyListeners();
  }

  /// Mulai sync: sekali jalan saat app start + retry berkala tiap
  /// 10 DETIK (Batch C9 — sebelumnya 60 detik, terlalu lambat untuk
  /// "sinkronisasi realtime"). Aman dipanggil berkali-kali (timer
  /// hanya dibuat sekali). Tiap tick: kirim antrean pending
  /// ([syncNow]) + tarik semua data gerai ([refreshSales] — satu
  /// pull per tick, guard di refreshSales). [period] default 10 detik;
  /// test boleh memendekkannya (produksi SELALU pakai default).
  void start({Duration period = const Duration(seconds: 10)}) {
    _timer ??= Timer.periodic(
      period,
      (_) {
        unawaited(syncNow());
        unawaited(refreshSales());
        // Batch C10 WS4: cek hangus Teh Masak tiap tick (sisa
        // kemarin hangus di hari baru — tercatat 'kedaluwarsa').
        unawaited(BrewService.instance.expireCheck());
      },
    );
    unawaited(syncNow());
    unawaited(refreshSales());
    unawaited(BrewService.instance.expireCheck());
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
    // SEC-1 R-02: EF sync-sales menolak push tanpa bukti PIN. Bukti
    // hanya hidup di memori (sesudah login/unlock) — jangan kirim
    // request yang pasti 403 (antrean tetap pending, bukan hilang).
    if (!CashierSessionService.instance.hasSessionProof) {
      debugPrint('Sync ditahan: bukti PIN sesi belum ada (SEC-1 R-02).');
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
      final result = await flushOutboxEntries(
        pending,
        _transport,
        proof: CashierSessionService.instance.sessionProof,
      );
      // v40: bukti PIN ditolak (kick / gerai dicabut) → kunci sesi.
      _checkKickReason(result.topReason);
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
      // Kiriman ditolak server (Batch C10 WS3): 'gudang_kurang' =
      // dua HP kirim bersamaan, gudang ternyata kurang untuk yang
      // kedua. Stok lokal dibalik + Owner diberitahu (bukan retry
      // diam-diam — event gagal DIHAPUS dari outbox oleh
      // reverseFailedSend; kirim ulang = kiriman BARU).
      if (result.failedErrors.isNotEmpty) {
        final byOutboxId = <String, OutboxEntry>{
          for (final e in pending) e.id: e,
        };
        for (final entry in result.failedErrors.entries) {
          if (entry.value != 'gudang_kurang') continue;
          final pendingEntry = byOutboxId[entry.key];
          if (pendingEntry == null || pendingEntry.kind != 'stock_send') {
            continue;
          }
          try {
            final raw = jsonDecode(pendingEntry.payload);
            final sendId = raw is Map ? raw['client_uuid'] : null;
            if (sendId is! String || sendId.isEmpty) continue;
            await PackageService.instance.reverseFailedSend(
              sendId: sendId,
              message:
                  'Kiriman ke gerai gagal — gudang ternyata kurang '
                  '(HP lain kirim duluan). Stok sudah dibalik, coba kirim lagi.',
            );
          } catch (e) {
            debugPrint('Balik kirim gagal gagal: $e');
          }
        }
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
  /// POS antar device). Batch C9: + [expenses] (pengeluaran gerai
  /// itu), [closedShifts] (shift yang sudah ditutup di jendela),
  /// [movements] (mutasi stok gerai itu di jendela — riwayat
  /// keluar-masuk barang). Batch C10: + [masterChanges] (perubahan
  /// master-data mentah, WS0), [sends] (kiriman ke gerai itu, WS3),
  /// [opnames] (baris opname gerai itu, WS6), [stockIns] (stok
  /// masuk gudang — hanya bila outletId = GUDANG_ID, WS1), [brews]
  /// (riwayat masak gerai itu, WS4). Throw bila Supabase belum
  /// dikonfigurasi / jawaban server tidak valid.
  Future<({
    List<SaleRecord> sales,
    List<StockItem> stock,
    List<ShiftSummary> shifts,
    List<Expense> expenses,
    List<ShiftSummary> closedShifts,
    List<StockMovement> movements,
    List<Map<String, dynamic>> masterChanges,
    List<Map<String, dynamic>> sends,
    List<Map<String, dynamic>> opnames,
    List<Map<String, dynamic>> stockIns,
    List<Map<String, dynamic>> brews,
    Map<String, dynamic>? cashier,
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
      // SEC-1 R-02: pull juga wajib bukti PIN.
      ...CashierSessionService.instance.sessionProof,
    });
    // v40: cek kick SEBELUM parse — parse melempar FormatException
    // untuk ok != true, tapi sesi harus sudah terkunci dulu.
    _checkKickReason(res['reason'] is String ? res['reason'] as String : null);
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
            shelfLifeDays: (s['shelf_life_days'] as num? ?? 0).toInt(),
          ),
        )
        .toList();
    final expenses =
        parsed.expenses.map(Expense.fromServer).toList();
    return (
      sales: sales,
      stock: stock,
      shifts: parsed.shifts,
      expenses: expenses,
      closedShifts: parsed.closedShifts,
      movements: parsed.movements,
      masterChanges: parsed.masterChanges,
      sends: parsed.sends,
      opnames: parsed.opnames,
      stockIns: parsed.stockIns,
      brews: parsed.brews,
      cashier: parsed.cashier,
    );
  }

  /// Tarik SEMUA data gerai ini dari server + gabungkan ke data
  /// lokal (Batch C9 — jantung sinkronisasi realtime):
  /// penjualan -> SaleHistory (merge, void sticky),
  /// pengeluaran -> ExpenseService (merge, hapus yang dihapus
  /// server), stok -> StockLevels (merge, qty delta-driven),
  /// shift terbuka -> adopsi bila perlu, shift tutup -> riwayat,
  /// mutasi -> [_lastMovements] (riwayat keluar-masuk barang).
  /// Batch C10: + master-data -> Menu/Topping/Stock/Package
  /// (WS0, last-write-wins, pending lokal TIDAK PERNAH ditimpa),
  /// kiriman -> PackageService (WS3), opname -> PackageService
  /// (WS6), masak -> BrewService (WS4). Gerai dicatat di
  /// [_syncedOutlets] sesudah pull berhasil (Dashboard WS7).
  /// Satu pull per tick (guard [_pullingSales] — pemanggilan
  /// bersamaan, mis. timer + tombol refresh, tidak dobel pull).
  /// Dipanggil saat app start, login/restore, buka Laporan/Riwayat,
  /// tombol refresh manual, + tiap 10 detik (lihat [start]).
  /// No-op bila offline / sedang pull / gagal. Tidak pernah throw.
  Future<void> refreshSales({String? outletId}) async {
    if (_pullingSales) return;
    if (!isConfigured) return;
    // SEC-1 R-02: pull pertama WAJIB sesudah login (bukti PIN ada).
    // Pemanggil pra-login (start() di main, restore sesi tanpa PIN)
    // tidak boleh menembak request yang pasti 403.
    if (!CashierSessionService.instance.hasSessionProof) {
      debugPrint('Pull ditahan: bukti PIN sesi belum ada (SEC-1 R-02).');
      return;
    }
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    _pullingSales = true;
    try {
      final now = DateTime.now();
      final from = now.subtract(const Duration(days: 30));
      final pulled = await pullOutlet(
        outletId: outlet,
        from: from,
        to: now,
      );
      // v40: izin kasir segar dari server tiap pull (10 dtk) —
      // Owner bisa mengubah izin ketika kasir sedang login.
      final cashierBlock = pulled.cashier;
      if (cashierBlock != null) {
        CashierSessionService.instance.applyPermissions(
          parseCashierPermissions(cashierBlock),
        );
      }
      await SaleHistoryService.instance.mergePulledSales(
        pulled.sales,
        outletId: outlet,
      );
      await ExpenseService.instance.mergePulledExpenses(
        pulled.expenses,
        outletId: outlet,
        from: from,
        to: now,
      );
      await StockService.instance.mergePulledStock(
        outlet,
        pulled.stock,
      );
      await CashShiftService.instance.applyPulledShifts(
        outletId: outlet,
        serverOpens: pulled.shifts,
      );
      await CashShiftService.instance.applyPulledClosedShifts(
        outlet,
        pulled.closedShifts,
      );
      // Batch C10 WS0/WS3/WS4/WS6: master-data + kiriman + opname
      // + masak dari server yang sama (satu pull, satu jendela).
      final masterChanges = <MasterChange>[];
      for (final row in pulled.masterChanges) {
        try {
          masterChanges.add(MasterChange.fromServer(row));
        } catch (e) {
          debugPrint('Refresh master lewati baris rusak: $e');
        }
      }
      if (masterChanges.isNotEmpty) {
        await StockService.instance.mergePulledRecipes(
          masterChanges.where((c) => c.entity == MasterEntity.recipe).toList(),
        );
        await StockService.instance.mergePulledStockConfigs(
          masterChanges
              .where((c) => c.entity == MasterEntity.stockItemConfig)
              .toList(),
        );
        await MenuService.instance.mergePulledProducts(
          masterChanges.where((c) => c.entity == MasterEntity.product).toList(),
        );
        await ToppingService.instance.mergePulledToppings(
          masterChanges.where((c) => c.entity == MasterEntity.topping).toList(),
        );
        await PackageService.instance.mergePulledMaster(masterChanges);
      }
      await PackageService.instance.mergePulledSends(pulled.sends);
      await PackageService.instance.mergePulledOpnames(pulled.opnames);
      await BrewService.instance.mergePulledBrews(pulled.brews);
      // Mutasi: server (30 hari) + lokal pending (belum terkirim) —
      // dedupe kunci clientUuid+nama (satu event bisa multi-bahan).
      final pending = await _pendingMovements(outlet);
      final seen = <String>{};
      final merged = <StockMovement>[];
      for (final m in [...pending, ...pulled.movements]) {
        if (seen.add('${m.clientUuid}|${m.name}')) merged.add(m);
      }
      merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _lastMovements = merged;
      _syncedOutlets.add(outlet);
      _lastPullAt = DateTime.now();
      notifyListeners();
    } catch (e) {
      debugPrint('Refresh penjualan gagal: $e');
    } finally {
      _pullingSales = false;
    }
  }

  /// Tarik stok gudang + riwayat stok masuk dari server (Batch C10
  /// WS1): gudang = pseudo-outlet GUDANG_ID — pull ini TIDAK
  /// menarik penjualan/shift (gudang tidak jualan). Dipanggil dari
  /// halaman Stok Masuk / Dashboard (Owner) + tiap tick? TIDAK —
  /// hanya on-demand (gudang berubah hanya bila Owner kirim/masuk
  /// stok; pull gudang tiap 10 dtk membebani tanpa perlu).
  /// No-op bila offline / gagal. Tidak pernah throw.
  Future<void> refreshWarehouse() async {
    if (!isConfigured) return;
    try {
      final now = DateTime.now();
      final from = now.subtract(const Duration(days: 30));
      final pulled = await pullOutlet(
        outletId: gudangOutletId,
        from: from,
        to: now,
      );
      await StockService.instance.mergePulledStock(
        gudangOutletId,
        pulled.stock,
      );
      await PackageService.instance.mergePulledStockIns(pulled.stockIns);
      _syncedOutlets.add(gudangOutletId);
      _lastPullAt = DateTime.now();
      notifyListeners();
    } catch (e) {
      debugPrint('Refresh gudang gagal: $e');
    }
  }

  /// Tarik SEMUA gerai sekaligus (Batch C10 WS7 — Dashboard Owner):
  /// sekuensial (satu per satu — 4 pull, bukan paralel, supaya
  /// tidak membebani server + guard _pullingSales tidak bentrok).
  /// Gerai yang gagal pull dilewati (tetap "Belum ada data
  /// tersinkron" bila belum pernah berhasil). Tidak pernah throw.
  Future<void> refreshAllOutlets() async {
    if (!isConfigured) return;
    for (final outlet in OutletService.instance.outlets) {
      await refreshSales(outletId: outlet.id);
    }
    await refreshWarehouse();
  }

  /// Mutasi stok lokal yang masih pending di outbox (belum terkirim)
  /// — tampil di riwayat keluar-masuk barang dengan label
  /// 'menunggu kirim' sampai server mengonfirmasi.
  Future<List<StockMovement>> _pendingMovements(String outletId) async {
    final list = <StockMovement>[];
    try {
      final pending = await _outbox.pendingEntries();
      for (final entry in pending) {
        if (entry.kind != 'stock_movement') continue;
        final raw = jsonDecode(entry.payload);
        if (raw is! Map) continue;
        final outlet = raw['outlet_id'];
        if (outlet is String && outlet.isNotEmpty && outlet != outletId) {
          continue;
        }
        final clientUuid = raw['client_uuid'];
        if (clientUuid is! String || clientUuid.isEmpty) continue;
        final items = raw['items'];
        if (items is! List) continue;
        final reason = raw['reason'];
        for (final it in items) {
          if (it is! Map) continue;
          final name = it['name'];
          final delta = it['delta'];
          if (name is! String || name.isEmpty) continue;
          if (delta is! num) continue;
          list.add((
            clientUuid: clientUuid,
            outletId: outletId,
            name: name,
            qtyDelta: delta.toDouble(),
            reason:
                reason is String && reason.isNotEmpty ? reason : 'penjualan',
            createdAt: entry.createdAt,
            pending: true,
          ));
        }
      }
    } catch (e) {
      debugPrint('Baca mutasi pending gagal: $e');
    }
    return list;
  }

  /// Tarik shift terbuka gerai ini dari server + adopsi bila perlu
  /// (Batch C8.2 WS6 — visibilitas antar device). Batch C9: alias
  /// ke [refreshSales] (pull lengkap — penjualan + pengeluaran +
  /// stok + shift) supaya semua pemanggil lama (login/restore,
  /// gate POS, Laporan) ikut mendapat data yang digabung, bukan
  /// cuma shift. Dipanggil saat login/app start + berkala
  /// (lihat start()). No-op bila offline / gagal (gate memakai
  /// data lokal terakhir). Tidak pernah throw.
  Future<void> refreshShifts({String? outletId}) async {
    await refreshSales(outletId: outletId);
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
        // Batch C9: kirim UTC (...Z) — string lokal tanpa offset
        // dibaca server sebagai +00 (bug jam +7 jam).
        'from': toUtcIsoString(from),
        'to': toUtcIsoString(to),
      });
      return parseShiftExpectedResponse(res);
    } catch (e) {
      debugPrint('Expected server gagal: $e');
      return null;
    }
  }
}
