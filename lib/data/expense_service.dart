import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'local/outbox_service.dart';
import 'outlet_service.dart';
import 'sync_payload.dart';

/// Satu pengeluaran (Batch C7).
class Expense {
  const Expense({
    required this.id,
    required this.outletId,
    required this.category,
    this.description = '',
    required this.amount,
    this.isCash = true,
    this.cashierName = '',
    required this.createdAt,
  });

  /// id = client_uuid (UUID v4) — kunci idempotency sync ke Supabase
  /// (kolom expenses.client_uuid, migrasi 009).
  final String id;

  /// Gerai tempat pengeluaran dicatat.
  final String outletId;

  /// Salah satu dari [expenseCategories] (bebas diisi manual di
  /// masa depan — sheet saat ini hanya menawarkan 4 pilihan).
  final String category;

  final String description;

  /// Nominal rupiah (> 0 — CHECK Supabase expenses.amount > 0).
  final int amount;

  /// true = keluar dari laci tunai (mengurangi expected tutup kas);
  /// false = non-tunai (transfer/dll, tidak sentuh laci).
  final bool isCash;

  /// Nama kasir yang mencatat (dari sesi kasir aktif; Owner = 'Owner').
  final String cashierName;

  final DateTime createdAt;
}

/// Kategori pengeluaran yang ditawarkan di sheet tambah.
const List<String> expenseCategories = [
  'Bahan Baku',
  'Operasional',
  'Gaji',
  'Lainnya',
];

/// Pengeluaran — di memori (ChangeNotifier) dan dicerminkan ke Drift
/// (tabel Expenses). Semua tulis ke DB dibungkus try/catch (pola
/// SaleHistoryService): gagal simpan tidak boleh crash app.
/// Tiap tambah/hapus diantrekan ke outbox kind 'expense' (pola C6) —
/// sync jalan fire-and-forget via SyncService.
class ExpenseService extends ChangeNotifier {
  ExpenseService._();

  static final ExpenseService instance = ExpenseService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<Expense> _expenses = [];
  bool _initialized = false;

  /// Semua pengeluaran, terbaru dulu (salinan).
  List<Expense> get expenses => List.unmodifiable(_expenses);

  bool get isInitialized => _initialized;

  /// Pengeluaran pada tanggal [day] (banding tahun/bulan/tanggal
  /// saja) untuk satu gerai ([outletId] null = gerai aktif sesi ini).
  List<Expense> expensesOn(DateTime day, {String? outletId}) {
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    return _expenses
        .where(
          (e) =>
              e.outletId == outlet &&
              e.createdAt.year == day.year &&
              e.createdAt.month == day.month &&
              e.createdAt.day == day.day,
        )
        .toList();
  }

  /// Baca Drift; tabel kosong = belum ada pengeluaran (bukan error).
  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.expenses).get();
      final list = rows
          .map(
            (r) => Expense(
              id: r.id,
              outletId: r.outletId,
              category: r.category,
              description: r.description,
              amount: r.amount,
              isCash: r.isCash,
              cashierName: r.cashierName,
              createdAt: r.createdAt,
            ),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _expenses = list;
    } catch (e) {
      debugPrint('Expense init gagal, daftar mulai kosong: $e');
      _expenses = [];
    }
    _initialized = true;
    notifyListeners();
  }

  /// Catat satu pengeluaran. [amount] harus > 0 (CHECK Supabase) —
  /// null = nominal tidak valid, tidak dicatat. [outletId] null =
  /// gerai aktif sesi ini. Mengembalikan pengeluaran yang dicatat.
  Future<Expense?> addExpense({
    required String category,
    String description = '',
    required int amount,
    bool isCash = true,
    String? outletId,
    String? cashierName,
  }) async {
    if (amount <= 0) return null;
    final expense = Expense(
      id: newClientUuid(),
      outletId: outletId ?? OutletService.instance.currentOutletId,
      category: category,
      description: description,
      amount: amount,
      isCash: isCash,
      cashierName: cashierName ?? '',
      createdAt: DateTime.now(),
    );
    _expenses = [expense, ..._expenses];
    notifyListeners();
    try {
      await _database.into(_database.expenses).insert(
            ExpensesCompanion.insert(
              id: expense.id,
              outletId: expense.outletId,
              category: expense.category,
              description: Value(expense.description),
              amount: expense.amount,
              isCash: Value(expense.isCash),
              cashierName: Value(expense.cashierName),
              createdAt: expense.createdAt,
            ),
          );
    } catch (e) {
      debugPrint('Expense simpan gagal (memori tetap ada): $e');
    }
    try {
      await OutboxService.instance.enqueueSale(
        _expensePayload(expense),
        kind: 'expense',
      );
    } catch (e) {
      debugPrint('Expense antre outbox gagal (lokal tetap): $e');
    }
    return expense;
  }

  /// Hapus pengeluaran (HANYA Owner — dicek di UI). Baris lokal
  /// dihapus + event 'expense' is_deleted=true diantrekan supaya
  /// baris Supabase ikut terhapus (server hapus by client_uuid).
  ///
  /// KEPUTUSAN C7: hapus = event, bukan hapus langsung — antrean
  /// yang sama dipakai semua jenis sync, hapus offline tetap jalan
  /// lalu tersinkron saat online, dan urutan FIFO menjaga event
  /// hapus selalu sesudah event tambah baris yang sama.
  /// false = id tidak ada.
  Future<bool> deleteExpense(String id) async {
    final i = _expenses.indexWhere((e) => e.id == id);
    if (i < 0) return false;
    final expense = _expenses[i];
    _expenses = List<Expense>.of(_expenses)..removeAt(i);
    notifyListeners();
    try {
      await (_database.delete(_database.expenses)
            ..where((t) => t.id.equals(id)))
          .go();
    } catch (e) {
      debugPrint('Expense hapus gagal simpan (memori tetap terhapus): $e');
    }
    try {
      await OutboxService.instance.enqueueSale(
        {
          'client_uuid': expense.id,
          'outlet_id': expense.outletId,
          'is_deleted': true,
          'created_at': expense.createdAt.toIso8601String(),
        },
        kind: 'expense',
      );
    } catch (e) {
      debugPrint('Expense hapus gagal antre outbox: $e');
    }
    return true;
  }

  Map<String, Object?> _expensePayload(Expense e) => {
        'client_uuid': e.id,
        'outlet_id': e.outletId,
        'category': e.category,
        'description': e.description,
        'amount': e.amount,
        'is_cash': e.isCash,
        'cashier_name': e.cashierName,
        'created_at': e.createdAt.toIso8601String(),
        'is_deleted': false,
      };
}
