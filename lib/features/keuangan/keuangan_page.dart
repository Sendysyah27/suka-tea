import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/cash.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/expense_service.dart';
import '../../data/models.dart';
import '../../data/outlet_service.dart';
import '../../data/sale_history.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import '../../features/login/cashier_session.dart';
import 'expense_sheet.dart';

/// Keuangan — HANYA Owner. Desain v2: hero card emerald gelap untuk
/// omzet + laba, lalu rincian per cara bayar.
///
/// DATA NYATA dari riwayat penjualan hari ini (bukan lagi angka contoh):
/// omzet, jumlah transaksi, jumlah cup, rata-rata per transaksi, dan
/// HPP + laba ESTIMASI (resep x harga bahan yang diatur Owner di tab
/// Stok — bukan lagi estimasi pasar). Laba BERSIH (Batch C7) = omzet −
/// HPP (estimasi) − pengeluaran hari ini; pengeluaran dicatat di
/// seksi Pengeluaran di bawah (Kasir + Owner boleh tambah, Owner
/// boleh hapus).
class KeuanganPage extends StatefulWidget {
  const KeuanganPage({super.key, required this.role});

  final AppRole role;

  @override
  State<KeuanganPage> createState() => _KeuanganPageState();
}

class _KeuanganPageState extends State<KeuanganPage> {
  /// Gerai yang ditampilkan (Batch C10 WS8): null = "Semua gerai"
  /// (total semua gerai yang sudah tersinkron di HP ini).
  String? _selectedOutletId;

  @override
  Widget build(BuildContext context) {
    if (!widget.role.canViewProfit) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Hanya Owner yang bisa melihat laba/HPP.\n'
            'Pembatasan ini ditegakkan oleh RLS Supabase, bukan hanya tampilan.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListenableBuilder(
      // Dengarkan juga StockService: harga bahan yang diubah Owner di
      // tab Stok langsung mengubah HPP/laba di halaman ini.
      // + ExpenseService (Batch C7): pengeluaran hari ini langsung
      // mengubah laba bersih + daftar pengeluaran di halaman ini.
      listenable: Listenable.merge([
        SaleHistoryService.instance,
        StockService.instance,
        ExpenseService.instance,
        SyncService.instance,
        OutletService.instance,
      ]),
      builder: (context, _) {
        // Transaksi void DIKECUALIKAN (Batch C1): omzet, laba, dan
        // rincian tidak menghitung transaksi yang sudah di-void.
        // Batch C10 WS8: gerai dipilih lewat dropdown (null = semua
        // gerai — statistik dijumlah per gerai, HPP pakai biaya
        // tiap gerai, bukan biaya gerai aktif).
        final now = DateTime.now();
        final outletIds = _selectedOutletId == null
            ? OutletService.instance.outlets.map((o) => o.id).toList()
            : [_selectedOutletId!];
        final today = <SaleRecord>[];
        final expensesTodayList = <Expense>[];
        var syncedCount = 0;
        for (final outletId in outletIds) {
          if (_selectedOutletId == null &&
              !SyncService.instance.hasSynced(outletId)) {
            continue;
          }
          syncedCount++;
          today.addAll(
            SaleHistoryService.instance.activeSalesOn(now, outletId: outletId),
          );
          expensesTodayList.addAll(
            ExpenseService.instance.expensesOn(now, outletId: outletId),
          );
        }
        final expensesToday = totalExpenses(expensesTodayList);
        if (today.isEmpty && expensesTodayList.isEmpty) {
          return Column(
            children: [
              _geraiDropdown(),
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Belum ada transaksi hari ini.\n'
                      'Omzet, laba, dan rincian muncul setelah ada penjualan.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: SukaTeaColors.muted),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        // HPP dari harga bahan yang diatur Owner di tab Stok
        // (Batch C1b) — bukan lagi const estimasi di seed_menu.
        // computeDailyStats dengan daftar kosong = semua 0 (aman
        // bila hari ini baru ada pengeluaran, belum ada penjualan).
        // "Semua gerai": hitung per gerai lalu jumlahkan (HPP tiap
        // gerai pakai biaya bahannya sendiri).
        final stats = _selectedOutletId == null
            ? _sumStats(outletIds, now)
            : computeDailyStats(
                today,
                StockService.instance.recipes,
                StockService.instance.costsByNameFor(_selectedOutletId!),
              );
        // Laba BERSIH (Batch C7) = omzet − HPP (estimasi) −
        // pengeluaran hari ini. Label "Laba (estimasi)" dipertahankan.
        final labaBersih = stats.labaEstimate - expensesToday;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _geraiDropdown(),
            if (_selectedOutletId == null &&
                syncedCount < outletIds.length)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Angka hanya dari gerai yang sudah tersinkron di HP '
                  'ini — gerai yang belum sync tidak ikut dihitung.',
                  style: TextStyle(
                    color: SukaTeaColors.muted,
                    fontSize: 12,
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: SukaTeaColors.emeraldDark,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Omzet hari ini',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    formatRupiah(stats.omzet),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 32,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Colors.white24, height: 1),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Laba (estimasi)',
                        style: TextStyle(color: Colors.white70),
                      ),
                      Text(
                        formatRupiah(labaBersih),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _row(
              'Transaksi hari ini',
              '${stats.txnCount} transaksi • ${stats.cups} cup',
            ),
            _row(
              'Rata-rata per transaksi',
              formatRupiah(stats.avgPerTxn),
            ),
            const SizedBox(height: 16),
            const Text(
              'Per cara bayar',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            for (final m in PaymentMethod.values)
              if ((stats.byMethod[m] ?? 0) > 0)
                _row(
                  m.label,
                  formatRupiah(stats.byMethod[m]!),
                  // Split (Batch C2) = campuran tunai + cashless —
                  // dot amber supaya tidak dikira murni tunai/cashless.
                  dotColor: m.isSplit
                      ? SukaTeaColors.amber
                      : (m.isCashless
                          ? SukaTeaColors.cashless
                          : SukaTeaColors.cash),
                ),
            const SizedBox(height: 16),
            const Text(
              'Biaya',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            _row(
              'HPP (estimasi)',
              '-${formatRupiah(stats.hppEstimate)}',
              dotColor: SukaTeaColors.danger,
            ),
            if (expensesToday > 0)
              _row(
                'Pengeluaran hari ini',
                '-${formatRupiah(expensesToday)}',
                dotColor: SukaTeaColors.danger,
              ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Laba (estimasi) = omzet − HPP (estimasi) − pengeluaran '
                'hari ini. HPP dihitung dari resep x harga bahan yang '
                'diatur Owner di tab Stok.',
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Pengeluaran',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                Text(
                  '${expensesTodayList.length} catatan',
                  style: const TextStyle(color: SukaTeaColors.muted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TapFeedback(
                child: OutlinedButton.icon(
                  onPressed: () => _addExpense(context),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Tambah Pengeluaran'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (expensesTodayList.isEmpty)
              const Text(
                'Belum ada pengeluaran hari ini.',
                style: TextStyle(color: SukaTeaColors.muted),
              )
            else
              for (final e in expensesTodayList) _expenseRow(context, e),
          ],
        );
      },
    );
  }

  /// Dropdown gerai (Batch C10 WS8): "Semua gerai" + 4 gerai.
  Widget _geraiDropdown() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String?>(
        initialValue: _selectedOutletId,
        decoration: const InputDecoration(labelText: 'Gerai'),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('Semua gerai'),
          ),
          for (final o in OutletService.instance.outlets)
            DropdownMenuItem<String?>(
              value: o.id,
              child: Text(o.name),
            ),
        ],
        onChanged: (v) => setState(() => _selectedOutletId = v),
      ),
    );
  }

  /// Jumlahkan statistik harian semua gerai (Batch C10 WS8 —
  /// "Semua gerai"): tiap gerai dihitung dengan biaya bahannya
  /// sendiri, lalu dijumlah (omzet, transaksi, cup, HPP, laba,
  /// per cara bayar). Gerai yang belum sync dilewati.
  DailyStats _sumStats(List<String> outletIds, DateTime day) {
    var omzet = 0;
    var txnCount = 0;
    var cups = 0;
    var hpp = 0;
    final byMethod = <PaymentMethod, int>{};
    for (final outletId in outletIds) {
      if (!SyncService.instance.hasSynced(outletId)) continue;
      final s = computeDailyStats(
        SaleHistoryService.instance.activeSalesOn(day, outletId: outletId),
        StockService.instance.recipes,
        StockService.instance.costsByNameFor(outletId),
      );
      omzet += s.omzet;
      txnCount += s.txnCount;
      cups += s.cups;
      hpp += s.hppEstimate;
      for (final e in s.byMethod.entries) {
        byMethod[e.key] = (byMethod[e.key] ?? 0) + e.value;
      }
    }
    return DailyStats(
      omzet: omzet,
      txnCount: txnCount,
      cups: cups,
      avgPerTxn: txnCount == 0 ? 0 : omzet ~/ txnCount,
      hppEstimate: hpp,
      labaEstimate: omzet - hpp,
      byMethod: byMethod,
    );
  }

  /// Sheet tambah pengeluaran (Batch C7) — halaman ini Owner-only;
  /// Kasir tambah lewat Laporan → Tambah Pengeluaran (fix review
  /// Jhon — kasir butuh jalan masuk di tengah shift). Nama pencatat
  /// dari sesi kasir aktif, fallback 'Owner'. Sesudah simpan, sync
  /// fire-and-forget (pola C6).
  Future<void> _addExpense(BuildContext context) async {
    final input = await showExpenseSheet(context);
    if (input == null) return;
    final cashierName =
        CashierSessionService.instance.cashierName ?? 'Owner';
    await ExpenseService.instance.addExpense(
      category: input.category,
      description: input.description,
      amount: input.amount,
      isCash: input.isCash,
      // Batch C10 WS8: bila satu gerai dipilih di dropdown,
      // pengeluaran dicatat di gerai itu; bila "Semua gerai",
      // dicatat di gerai aktif (perilaku lama).
      outletId: _selectedOutletId,
      cashierName: cashierName,
    );
    unawaited(SyncService.instance.syncNow());
  }

  /// Hapus pengeluaran (HANYA Owner — halaman ini Owner-only).
  /// Konfirmasi dulu; hapus lokal + antre event is_deleted=true.
  Future<void> _confirmDeleteExpense(
    BuildContext context,
    Expense expense,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hapus pengeluaran?'),
        content: Text(
          '${expense.category} • ${formatRupiah(expense.amount)}'
          '${expense.description.isNotEmpty ? '\n${expense.description}' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Ya, hapus'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ExpenseService.instance.deleteExpense(expense.id);
      unawaited(SyncService.instance.syncNow());
    }
  }

  Widget _expenseRow(BuildContext context, Expense e) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.category,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (e.description.isNotEmpty)
                    Text(
                      e.description,
                      style: const TextStyle(color: SukaTeaColors.muted),
                    ),
                  Text(
                    '${e.isCash ? 'Tunai' : 'Non-tunai'}'
                    ' • ${e.cashierName} • ${_clock(e.createdAt)}',
                    style: const TextStyle(color: SukaTeaColors.muted),
                  ),
                ],
              ),
            ),
            Text(
              '-${formatRupiah(e.amount)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Hapus pengeluaran',
              onPressed: () => _confirmDeleteExpense(context, e),
            ),
          ],
        ),
      ),
    );
  }

  String _clock(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Widget _row(String label, String value, {Color? dotColor}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (dotColor != null) ...[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(child: Text(label)),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
