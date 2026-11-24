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
    required this.cashierName,
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

  /// Nama kasir yang membuka shift (dari sesi kasir aktif;
  /// Owner = 'Owner').
  final String cashierName;

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
        cashierName: cashierName,
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
  /// tidak ada). MAKSIMAL 1 shift open per outlet.
  CashShift? get openShift {
    final outlet = OutletService.instance.currentOutletId;
    for (final s in _shifts) {
      if (s.outletId == outlet && s.isOpen) return s;
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
              cashierName: r.cashierName,
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
  /// gerai itu (pemanggil menampilkan dialog penolakan — buka baru
  /// hanya boleh sesudah shift lama ditutup). Modal awal boleh 0.
  Future<CashShift?> openNewShift({
    required int openingFloat,
    String? outletId,
    String? cashierName,
  }) async {
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    if (_shifts.any((s) => s.outletId == outlet && s.isOpen)) return null;
    final shift = CashShift(
      id: newClientUuid(),
      outletId: outlet,
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
  /// expected = modal awal + tunai masuk (jendela buka s.d. sekarang)
  /// − pengeluaran TUNAI jendela yang sama; difference = counted −
  /// expected. null = shift tidak ada / sudah ditutup. Jendela
  /// dihitung dari data LOKAL (riwayat + pengeluaran HP ini) —
  /// penjualan gerai lain / HP lain tidak ikut (batasan C7).
  Future<CashShift?> closeShift(
    CashShift shift, {
    required int countedCash,
    String note = '',
  }) async {
    final i = _shifts.indexWhere((s) => s.id == shift.id);
    if (i < 0 || _shifts[i].isClosed) return null;
    final now = DateTime.now();
    final cashIn = cashInWindow(
      SaleHistoryService.instance.sales,
      outletId: shift.outletId,
      from: shift.openedAt,
      to: now,
    );
    final cashOut = cashExpensesInWindow(
      ExpenseService.instance.expenses,
      outletId: shift.outletId,
      from: shift.openedAt,
      to: now,
    );
    final expected = expectedCash(
      openingFloat: shift.openingFloat,
      cashIn: cashIn,
      cashExpenses: cashOut,
    );
    final closed = _shifts[i].copyWith(
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
        'cashier_name': s.cashierName,
        'opened_at': s.openedAt.toIso8601String(),
        'opening_float': s.openingFloat,
        'closed_at': s.closedAt?.toIso8601String(),
        'counted_cash': s.countedCash,
        'expected_cash': s.expectedCash,
        'difference': s.difference,
        'status': s.status,
        'note': s.note,
      };
}
