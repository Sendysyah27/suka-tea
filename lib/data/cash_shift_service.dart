import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../core/utils/cash.dart';
import 'expense_service.dart';
import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'outlet_service.dart';
import 'sale_history.dart';
import 'sync_payload.dart';

/// Satu shift kas (Batch C7).
class CashShift {
  const CashShift({
    required this.id,
    required this.outletId,
    this.cashierId = '',
    required this.cashierName,
    this.closedByCashierId = '',
    this.closedByCashierName = '',
    required this.openedAt,
    required this.openingFloat,
    this.closedAt,
    this.countedCash,
    this.expectedCash,
    this.difference,
    this.status = 'open',
    this.note = '',
  });

  /// id = client_uuid (UUID v4) — kunci idempotency sync ke Supabase
  /// (cash_shifts.client_uuid, migrasi 009; upsert last-write-wins).
  final String id;

  final String outletId;

  /// UUID kasir PEMBUKA dari server (Batch C8.2 WS6 — tampil di
  /// kartu "Kas & Shift"); '' = sesi lama / Owner.
  final String cashierId;

  /// Nama kasir yang membuka shift (dari sesi kasir aktif;
  /// Owner = 'Owner').
  final String cashierName;

  /// UUID + nama kasir/Owner PENUTUP (Batch C8.2 WS6 — audit, siapa
  /// yang menutup); '' selama shift masih open.
  final String closedByCashierId;
  final String closedByCashierName;

  final DateTime openedAt;

  /// Modal awal laci saat shift dibuka (boleh 0).
  final int openingFloat;

  /// null selama shift masih open.
  final DateTime? closedAt;

  /// Uang hasil hitungan laci saat tutup (null selama open).
  final int? countedCash;

  /// Uang yang seharusnya ada di laci saat tutup (null selama open).
  final int? expectedCash;

  /// counted − expected (boleh negatif = kurang; null selama open).
  final int? difference;

  /// 'open' / 'closed'.
  final String status;

  final String note;

  bool get isOpen => status == 'open';
  bool get isClosed => status == 'closed';

  CashShift copyWith({
    String? cashierId,
    String? closedByCashierId,
    String? closedByCashierName,
    DateTime? closedAt,
    int? countedCash,
    int? expectedCash,
    int? difference,
    String? status,
    String? note,
  }) =>
      CashShift(
        id: id,
        outletId: outletId,
        cashierId: cashierId ?? this.cashierId,
        cashierName: cashierName,
        closedByCashierId: closedByCashierId ?? this.closedByCashierId,
        closedByCashierName:
            closedByCashierName ?? this.closedByCashierName,
        openedAt: openedAt,
        openingFloat: openingFloat,
        closedAt: closedAt ?? this.closedAt,
        countedCash: countedCash ?? this.countedCash,
        expectedCash: expectedCash ?? this.expectedCash,
        difference: difference ?? this.difference,
        status: status ?? this.status,
        note: note ?? this.note,
      );
}

/// Shift kas — di memori (ChangeNotifier) dan dicerminkan ke Drift
/// (tabel CashShifts). Semua tulis ke DB dibungkus try/catch (pola
/// SaleHistoryService): gagal simpan tidak boleh crash app.
/// Tiap buka/tutup diantrekan ke outbox kind 'shift' (pola C6) —
/// sync jalan fire-and-forget via SyncService; server upsert by
/// client_uuid (last-write-wins: event tutup menimpa event buka).
class CashShiftService extends ChangeNotifier {
  CashShiftService._();

  static final CashShiftService instance = CashShiftService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<CashShift> _shifts = [];
  bool _initialized = false;

  /// Semua shift, terbaru dulu (salinan).
  List<CashShift> get shifts => List.unmodifiable(_shifts);

  bool get isInitialized => _initialized;

  /// Shift yang masih terbuka di gerai aktif sesi ini (null bila
  /// tidak ada). MAKSIMAL 1 shift open per outlet (Batch C8.2 WS6:
  /// laci HANYA SATU — 2 kasir berbagi 1 shift, yang beda hanya
  /// akses/PIN, bukan shift-nya).
  CashShift? get openShift =>
      openShiftFor(OutletService.instance.currentOutletId);

  /// Shift yang masih terbuka di gerai [outletId] (null bila tidak
  /// ada). Dipakai gate POS KasirPage (gerai aktif) + Laporan.
  CashShift? openShiftFor(String outletId) {
    for (final s in _shifts) {
      if (s.outletId == outletId && s.isOpen) return s;
    }
    return null;
  }

  /// Shift yang sudah ditutup di gerai [outletId] (null = gerai
  /// aktif), terbaru dulu. Riwayat cukup gerai aktif — Owner ganti
  /// gerai via Ganti Gerai (batasan C7, dicatat di laporan).
  List<CashShift> closedShifts({String? outletId}) {
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    return _shifts
        .where((s) => s.outletId == outlet && s.isClosed)
        .toList();
  }

  /// Baca Drift; tabel kosong = belum ada shift (bukan error).
  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.cashShifts).get();
      final list = rows
          .map(
            (r) => CashShift(
              id: r.id,
              outletId: r.outletId,
              cashierId: r.cashierId ?? '',
              cashierName: r.cashierName,
              closedByCashierId: r.closedByCashierId ?? '',
              closedByCashierName: r.closedByCashierName,
              openedAt: r.openedAt,
              openingFloat: r.openingFloat,
              closedAt: r.closedAt,
              countedCash: r.countedCash,
              expectedCash: r.expectedCash,
              difference: r.difference,
              status: r.status,
              note: r.note,
            ),
          )
          .toList()
        ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
      _shifts = list;
    } catch (e) {
      debugPrint('Shift init gagal, daftar mulai kosong: $e');
      _shifts = [];
    }
    _initialized = true;
    notifyListeners();
  }

  /// Buka shift baru di gerai aktif. null = masih ada shift open di
  /// gerai itu (aturan C7 DIPERTAHANKAN Batch C8.2 WS6: SATU shift
  /// per gerai — pemanggil menampilkan dialog penolakan; buka baru
  /// hanya boleh sesudah shift lama ditutup). Siapa pun yang login
  /// (kasir mana pun / Owner) boleh membuka; [cashierId]/[cashierName]
  /// = pembuka (Owner = '' / 'Owner'). Modal awal boleh 0.
  Future<CashShift?> openNewShift({
    required int openingFloat,
    String? outletId,
    String? cashierId,
    String? cashierName,
  }) async {
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    if (_shifts.any((s) => s.outletId == outlet && s.isOpen)) return null;
    final shift = CashShift(
      id: newClientUuid(),
      outletId: outlet,
      cashierId: cashierId ?? '',
      cashierName: cashierName ?? '',
      openedAt: DateTime.now(),
      openingFloat: openingFloat,
    );
    _shifts = [shift, ..._shifts];
    notifyListeners();
    try {
      await _database.into(_database.cashShifts).insert(
            CashShiftsCompanion.insert(
              id: shift.id,
              outletId: shift.outletId,
              cashierId: Value(shift.cashierId.isEmpty ? null : shift.cashierId),
              cashierName: shift.cashierName,
              openedAt: shift.openedAt,
              openingFloat: shift.openingFloat,
              status: const Value('open'),
              note: const Value(''),
            ),
          );
    } catch (e) {
      debugPrint('Shift buka gagal simpan (memori tetap ada): $e');
    }
    try {
      await OutboxService.instance.enqueueSale(
        _shiftPayload(shift),
        kind: 'shift',
      );
    } catch (e) {
      debugPrint('Shift buka gagal antre outbox (lokal tetap): $e');
    }
    return shift;
  }

  /// Tutup shift [shift] dengan uang hasil hitungan [countedCash].
  /// Siapa pun yang login (kasir mana pun / Owner) boleh menutup;
  /// [closedByCashierId]/[closedByCashierName] = penutup (audit —
  /// Owner = '' / 'Owner'). expected = modal awal + tunai masuk
  /// (jendela buka s.d. sekarang) − pengeluaran TUNAI jendela yang
  /// sama; difference = counted − expected. null = shift tidak ada /
  /// sudah ditutup.
  /// [expectedOverride] (Batch C8.2 WS6): angka expected dari SERVER
  /// (semua kasir + semua device gerai itu) — dipakai bila berhasil
  /// diambil; null = hitungan LOKAL (riwayat + pengeluaran HP ini
  /// saja — pemanggil WAJIB melabelinya "perkiraan (offline)").
  /// Jendela dihitung dari data LOKAL (riwayat + pengeluaran HP ini)
  /// — penjualan gerai lain / HP lain tidak ikut (batasan C7).
  Future<CashShift?> closeShift(
    CashShift shift, {
    required int countedCash,
    String note = '',
    String closedByCashierId = '',
    String closedByCashierName = '',
    int? expectedOverride,
  }) async {
    final i = _shifts.indexWhere((s) => s.id == shift.id);
    if (i < 0 || _shifts[i].isClosed) return null;
    final now = DateTime.now();
    final expected = expectedOverride ??
        expectedCash(
          openingFloat: shift.openingFloat,
          cashIn: cashInWindow(
            SaleHistoryService.instance.sales,
            outletId: shift.outletId,
            from: shift.openedAt,
            to: now,
          ),
          cashExpenses: cashExpensesInWindow(
            ExpenseService.instance.expenses,
            outletId: shift.outletId,
            from: shift.openedAt,
            to: now,
          ),
        );
    final closed = _shifts[i].copyWith(
      closedByCashierId: closedByCashierId,
      closedByCashierName: closedByCashierName,
      closedAt: now,
      countedCash: countedCash,
      expectedCash: expected,
      difference: cashDifference(counted: countedCash, expected: expected),
      status: 'closed',
      note: note,
    );
    _shifts = List<CashShift>.of(_shifts)..[i] = closed;
    notifyListeners();
    try {
      await (_database.update(_database.cashShifts)
            ..where((t) => t.id.equals(closed.id)))
          .write(
        CashShiftsCompanion(
          closedByCashierId: Value(
            closed.closedByCashierId.isEmpty
                ? null
                : closed.closedByCashierId,
          ),
          closedByCashierName: Value(closed.closedByCashierName),
          closedAt: Value(closed.closedAt),
          countedCash: Value(closed.countedCash),
          expectedCash: Value(closed.expectedCash),
          difference: Value(closed.difference),
          status: const Value('closed'),
          note: Value(closed.note),
        ),
      );
    } catch (e) {
      debugPrint('Shift tutup gagal simpan (memori tetap tertutup): $e');
    }
    try {
      await OutboxService.instance.enqueueSale(
        _shiftPayload(closed),
        kind: 'shift',
      );
    } catch (e) {
      debugPrint('Shift tutup gagal antre outbox (lokal tetap): $e');
    }
    return closed;
  }

  Map<String, Object?> _shiftPayload(CashShift s) => {
        'client_uuid': s.id,
        'outlet_id': s.outletId,
        'cashier_id': s.cashierId,
        'cashier_name': s.cashierName,
        'closed_by_cashier_id': s.closedByCashierId,
        'closed_by_cashier_name': s.closedByCashierName,
        'opened_at': s.openedAt.toIso8601String(),
        'opening_float': s.openingFloat,
        'closed_at': s.closedAt?.toIso8601String(),
        'counted_cash': s.countedCash,
        'expected_cash': s.expectedCash,
        'difference': s.difference,
        'status': s.status,
        'note': s.note,
      };

  /// Terapkan shift terbuka dari server sesudah pull (Batch C8.2
  /// WS6 — visibilitas antar device). Keputusan adopsi murni lewat
  /// [pickAdoptedShift] (lihat sync_payload.dart): shift server
  /// hanya diadopsi bila tidak ada shift lokal, atau shift lokal
  /// sudah terkirim DAN kalah awal dari shift server. Shift yang
  /// diadopsi disimpan lokal (tanpa antre outbox — sudah ada di
  /// server) supaya gate POS + kartu "Kas & Shift" melihatnya.
  /// Tidak pernah throw.
  Future<void> applyPulledShifts({
    required String outletId,
    required List<ShiftSummary> serverOpens,
  }) async {
    try {
      CashShift? localOpen;
      for (final s in _shifts) {
        if (s.outletId == outletId && s.isOpen) {
          localOpen = s;
          break;
        }
      }
      final localPending = localOpen == null
          ? false
          : await _isOpenEventPending(localOpen.id);
      final adopted = pickAdoptedShift(
        localOpen: localOpen == null ? null : _toSummary(localOpen),
        localPending: localPending,
        serverOpens: serverOpens,
      );
      if (adopted == null) return;
      await _adoptSummary(
        adopted: adopted,
        outletId: outletId,
        discardLocalId: localOpen?.id,
      );
    } catch (e) {
      debugPrint('Terapkan shift server gagal: $e');
    }
  }

  /// Adopsi shift server sesudah push event buka lokal kena dedupe
  /// (Batch C8.2 WS6): shift lokal [adoption.localClientUuid] kalah
  /// awal — buang duplikat lokalnya (baris shift + event outbox-nya)
  /// lalu simpan shift server sebagai shift terbuka gerai ini.
  /// Tidak pernah throw.
  Future<void> adoptServerShift(ShiftAdoption adoption) async {
    try {
      if (adoption.localClientUuid.isEmpty) return;
      final local = _shifts
          .where((s) => s.id == adoption.localClientUuid)
          .toList();
      if (local.isEmpty) return;
      await _adoptSummary(
        adopted: (
          clientUuid: adoption.existingClientUuid,
          outletId: local.first.outletId,
          cashierId: adoption.existingCashierId,
          cashierName: adoption.existingCashierName,
          openedAt: adoption.existingOpenedAt,
          openingFloat: adoption.existingOpeningFloat,
          status: 'open',
          closedAt: null,
          closedByCashierId: '',
          closedByCashierName: '',
        ),
        outletId: local.first.outletId,
        discardLocalId: adoption.localClientUuid,
      );
    } catch (e) {
      debugPrint('Adopsi shift server gagal: $e');
    }
  }

  /// Ganti shift lokal [discardLocalId] (bila ada) dengan shift
  /// server [adopted]: hapus baris + event outbox duplikat, lalu
  /// simpan shift server sebagai shift terbuka (tanpa antre outbox).
  Future<void> _adoptSummary({
    required ShiftSummary adopted,
    required String outletId,
    String? discardLocalId,
  }) async {
    if (discardLocalId != null && discardLocalId != adopted.clientUuid) {
      _shifts = _shifts.where((s) => s.id != discardLocalId).toList();
      try {
        await (_database.delete(_database.cashShifts)
              ..where((t) => t.id.equals(discardLocalId)))
            .go();
      } catch (e) {
        debugPrint('Adopsi shift gagal hapus duplikat lokal: $e');
      }
      await _deleteShiftOutboxEvents(discardLocalId);
    }
    if (_shifts.any((s) => s.id == adopted.clientUuid)) return;
    final shift = CashShift(
      id: adopted.clientUuid,
      outletId: outletId,
      cashierId: adopted.cashierId,
      cashierName: adopted.cashierName,
      openedAt: adopted.openedAt,
      openingFloat: adopted.openingFloat,
    );
    _shifts = [shift, ..._shifts];
    notifyListeners();
    try {
      await _database.into(_database.cashShifts).insert(
            CashShiftsCompanion.insert(
              id: shift.id,
              outletId: shift.outletId,
              cashierId: Value(shift.cashierId.isEmpty ? null : shift.cashierId),
              cashierName: shift.cashierName,
              openedAt: shift.openedAt,
              openingFloat: shift.openingFloat,
              status: const Value('open'),
              note: const Value(''),
            ),
            mode: InsertMode.insertOrReplace,
          );
    } catch (e) {
      debugPrint('Adopsi shift gagal simpan (memori tetap ada): $e');
    }
  }

  /// true = event BUKA shift [clientUuid] masih pending di outbox
  /// (belum terkirim — server belum tahu shift ini).
  Future<bool> _isOpenEventPending(String clientUuid) async {
    try {
      final pending = await OutboxService.instance.pendingEntries();
      for (final entry in pending) {
        if (entry.kind != 'shift') continue;
        final raw = jsonDecode(entry.payload);
        if (raw is Map &&
            raw['client_uuid'] == clientUuid &&
            raw['status'] != 'closed') {
          return true;
        }
      }
    } catch (e) {
      debugPrint('Cek pending shift gagal: $e');
    }
    return false;
  }

  /// Hapus SEMUA entri outbox (pending + terkirim) milik shift
  /// [clientUuid] — dipakai saat duplikat lokal dibuang (adopsi).
  Future<void> _deleteShiftOutboxEvents(String clientUuid) async {
    try {
      final rows = await _database.select(_database.outboxEntries).get();
      final ids = <String>[];
      for (final row in rows) {
        if (row.kind != 'shift') continue;
        final raw = jsonDecode(row.payload);
        if (raw is Map && raw['client_uuid'] == clientUuid) {
          ids.add(row.id);
        }
      }
      if (ids.isNotEmpty) await _database.deleteOutboxEntries(ids);
    } catch (e) {
      debugPrint('Adopsi shift gagal hapus event outbox: $e');
    }
  }

  ShiftSummary _toSummary(CashShift s) => (
        clientUuid: s.id,
        outletId: s.outletId,
        cashierId: s.cashierId,
        cashierName: s.cashierName,
        openedAt: s.openedAt,
        openingFloat: s.openingFloat,
        status: s.status,
        closedAt: s.closedAt,
        closedByCashierId: s.closedByCashierId,
        closedByCashierName: s.closedByCashierName,
      );
}
