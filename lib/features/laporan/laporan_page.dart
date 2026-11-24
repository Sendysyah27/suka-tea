import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/cash.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/cash_shift_service.dart';
import '../../data/expense_service.dart';
import '../../data/outlet_service.dart';
import '../../data/sale_history.dart';
import '../../data/sheets_export.dart';
import '../../data/sync_service.dart';
import '../../features/login/cashier_session.dart';
import '../keuangan/expense_sheet.dart';
import '../riwayat/riwayat_page.dart';
import 'shift_sheets.dart';

/// Laporan & Tutup Kas — rekap hari ini + shift kas (buka/tutup,
/// expected, selisih) + export ke Google Sheets (Edge Function,
/// Owner saja). Desain v2: kartu radius 20, tombol 56px.
///
/// DATA NYATA dari riwayat penjualan hari ini: penjualan tunai, produk
/// terlaris (top 3), dan tombol ke Riwayat.
///
/// Batch C7: rekonsiliasi manual lama (input modal awal + hitung laci
/// di halaman, tidak tersimpan) DIGANTI shift kas persisten — Buka
/// Shift (modal awal) → Tutup Kas (uang dihitung + selisih) → riwayat
/// shift gerai aktif. Kasir + Owner boleh buka/tutup shift; expected
/// dihitung dari data lokal HP ini (tunai masuk jendela shift −
/// pengeluaran tunai jendela yang sama).
///
/// Batch C8.2 WS6: laci HANYA SATU — 2 kasir berbagi 1 shift per
/// gerai (yang beda hanya akses/PIN). Expected tutup kas diambil dari
/// SERVER bila online (semua kasir + semua device gerai itu); bila
/// offline, hitungan lokal berlabel "perkiraan (offline)". Shift
/// yang dibuka di device lain ditarik berkala (refreshShifts) supaya
/// kartu "Kas & Shift" + gate POS melihatnya.
class LaporanPage extends StatefulWidget {
  const LaporanPage({super.key, required this.role, required this.onExitGerai});

  final AppRole role;

  /// Keluar gerai (hapus sesi kasir + kembali ke layar pilih gerai).
  /// Diteruskan dari _LoginGate lewat SukaTeaShell.
  final VoidCallback onExitGerai;

  @override
  State<LaporanPage> createState() => _LaporanPageState();
}

class _LaporanPageState extends State<LaporanPage> {
  /// Nama pencatat shift: sesi kasir aktif; Owner (tanpa sesi) = 'Owner'.
  String get _cashierName =>
      CashierSessionService.instance.cashierName ??
      (widget.role == AppRole.owner ? 'Owner' : 'Kasir');

  /// UUID kasir pembuka/penutup dari server; Owner (tanpa sesi) = ''.
  String get _cashierId =>
      CashierSessionService.instance.cashierId ?? '';

  @override
  void initState() {
    super.initState();
    // Tarik shift terbuka gerai ini (bisa dibuka di device lain).
    unawaited(SyncService.instance.refreshShifts());
  }

  /// Buka shift baru (Batch C7, alur via openShiftFlow C8.2).
  /// null dari sheet = batal; null dari service = masih ada shift
  /// open (snackbar penolakan dari openShiftFlow).
  Future<void> _openShift() async {
    final shift = await openShiftFlow(
      context,
      cashierId: _cashierId,
      cashierName: _cashierName,
    );
    if (shift != null) unawaited(SyncService.instance.syncNow());
  }

  /// Tutup shift [shift]: expected diambil dari SERVER dulu (semua
  /// kasir + semua device gerai itu); gagal/offline = hitungan lokal
  /// berlabel "perkiraan (offline)" di sheet. Lalu sheet input uang
  /// dihitung + preview selisih, lalu tutup + ringkasan.
  Future<void> _closeShift(CashShift shift) async {
    final now = DateTime.now();
    final server = await SyncService.instance.fetchShiftExpected(
      outletId: shift.outletId,
      from: shift.openedAt,
      to: now,
    );
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
    // Server mengembalikan cash_in/cash_out TANPA modal awal —
    // expected lengkap = modal + cash_in − cash_out (sama rumusnya
    // dengan hitungan lokal, lihat expectedCash di cash.dart).
    final expected = server == null
        ? expectedCash(
            openingFloat: shift.openingFloat,
            cashIn: cashIn,
            cashExpenses: cashOut,
          )
        : shift.openingFloat + server.cashIn - server.cashOut;
    final input = await showCloseShiftSheet(
      context,
      shift: shift,
      expected: expected,
      // Rincian di sheet harus cocok dengan expected yang ditampilkan:
      // angka server bila expected dari server, angka lokal bila offline.
      cashIn: server?.cashIn ?? cashIn,
      cashExpenses: server?.cashOut ?? cashOut,
      expectedLabel: server == null
          ? 'Expected perkiraan (offline) — hanya penjualan HP ini.'
          : null,
    );
    if (input == null) return;
    final closed = await CashShiftService.instance.closeShift(
      shift,
      countedCash: input.countedCash,
      note: input.note,
      closedByCashierId: _cashierId,
      closedByCashierName: _cashierName,
      expectedOverride: expected,
    );
    if (!mounted) return;
    if (closed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shift sudah ditutup.')),
      );
      return;
    }
    unawaited(SyncService.instance.syncNow());
    final diff = closed.difference ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Shift ditutup — selisih ${formatRupiah(diff)} '
          '(${diff == 0 ? 'pas' : diff > 0 ? 'lebih' : 'kurang'}).',
        ),
      ),
    );
  }

  /// Tambah pengeluaran (Batch C7, fix review Jhon): halaman ini
  /// bisa dibuka Kasir maupun Owner, jadi kasir bisa mencatat
  /// pengeluaran laci di tengah shift — KeuanganPage Owner-only,
  /// jadi tanpa tombol ini kasir tidak punya jalan masuk. Nama
  /// pencatat dari sesi kasir aktif; Owner (tanpa sesi) = 'Owner'.
  /// Sesudah simpan, sync fire-and-forget (pola C6).
  Future<void> _addExpense() async {
    final input = await showExpenseSheet(context);
    if (input == null) return;
    await ExpenseService.instance.addExpense(
      category: input.category,
      description: input.description,
      amount: input.amount,
      isCash: input.isCash,
      cashierName: _cashierName,
    );
    unawaited(SyncService.instance.syncNow());
  }

  /// Konfirmasi keluar gerai (Batch C5): sesi kasir dihapus — buka
  /// app lagi harus pilih gerai + PIN kasir lagi. Keranjang yang
  /// belum dibayar ikut hilang (shell dibuat ulang per login).
  Future<void> _confirmExitGerai() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ganti gerai?'),
        content: const Text(
          'Sesi kasir di gerai ini dihapus. Untuk masuk lagi harus '
          'pilih gerai dan masukkan PIN kasir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Ya, keluar gerai'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) widget.onExitGerai();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // + CashShiftService + ExpenseService (Batch C7): angka live
      // shift (tunai masuk / expected sejauh ini) berubah saat ada
      // penjualan atau pengeluaran baru.
      listenable: Listenable.merge([
        SaleHistoryService.instance,
        CashShiftService.instance,
        ExpenseService.instance,
      ]),
      builder: (context, _) {
        // Transaksi void DIKECUALIKAN (Batch C1): tutup kasir +
        // terlaris tidak menghitung transaksi yang sudah di-void.
        final today =
            SaleHistoryService.instance.activeSalesOn(DateTime.now());
        // Tunai di laci (Batch C2): tunai penuh + BAGIAN TUNAI dari
        // transaksi split (total - bagian QRIS). Kembalian sudah
        // diperhitungkan di cashInDrawer — tunai lebih bayar yang
        // kembali ke pelanggan tidak menambah isi laci.
        final tunaiSales =
            today.fold(0, (sum, s) => sum + s.cashInDrawer);
        final top = topProducts(today);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rekap hari ini',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Rekap per cara bayar + rekonsiliasi kas tunai.',
                      style: TextStyle(color: SukaTeaColors.muted),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (today.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Belum ada transaksi hari ini.\n'
                    'Angka di bawah terisi setelah ada penjualan.',
                    style: TextStyle(color: SukaTeaColors.muted),
                  ),
                ),
              )
            else ...[
              _row('Penjualan tunai hari ini', tunaiSales),
              _row('Jumlah transaksi', today.length, isCount: true),
              const SizedBox(height: 12),
              const Text(
                'Produk terlaris hari ini',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 8),
              if (top.isEmpty)
                const Text(
                  'Belum ada produk terjual.',
                  style: TextStyle(color: SukaTeaColors.muted),
                )
              else
                for (var i = 0; i < top.length; i++)
                  _row(
                    '${i + 1}. ${top[i].name}',
                    top[i].qty,
                    isCount: true,
                    suffix: ' cup',
                  ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 12),
            const Text(
              'Kas & Shift',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            _shiftCard(context),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TapFeedback(
                child: OutlinedButton.icon(
                  onPressed: _addExpense,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Tambah Pengeluaran'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TapFeedback(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RiwayatPage(role: widget.role),
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  child: const Text('Lihat Riwayat'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Export Sheets bukan bagian frame FigCraft 07, tapi
            // fungsinya dipertahankan (bukan dihapus): tombol
            // outline full-width di bawah baris utama.
            // HANYA Owner (Batch C3): Kasir tidak melihat tombolnya.
            // shiftId = tanggal hari ini (tutup kasir = harian; app
            // tidak punya konsep shift).
            if (widget.role.canExportSheets)
              SizedBox(
                width: double.infinity,
                child: TapFeedback(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final result = await exportShiftToSheets(
                        outletId: OutletService.instance.currentOutletId,
                        shiftId: shiftIdForToday(),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(result.message)),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 56),
                    ),
                    icon: const Icon(Icons.table_chart),
                    label: const Text('Export Sheets'),
                  ),
                ),
              ),
            // Ganti Gerai (Batch C5): keluar dari gerai aktif — sesi
            // kasir dihapus, kembali ke layar pilih gerai. Buka app
            // lagi langsung masuk gerai selama sesi belum dihapus.
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TapFeedback(
                child: OutlinedButton.icon(
                  onPressed: _confirmExitGerai,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Ganti Gerai'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Kartu "Kas & Shift" (Batch C7): belum ada shift open → tombol
  /// Buka Shift; ada yang open → angka live + tombol Tutup Kas;
  /// di bawahnya riwayat shift closed gerai aktif (maks 5 terakhir).
  Widget _shiftCard(BuildContext context) {
    final open = CashShiftService.instance.openShift;
    if (open == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Belum ada shift terbuka.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Buka shift di awal jualan supaya tutup kas tercatat.',
                style: TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 12),
              TapFeedback(
                child: FilledButton(
                  onPressed: _openShift,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  child: const Text('Buka Shift'),
                ),
              ),
              ..._closedHistory(),
            ],
          ),
        ),
      );
    }
    final now = DateTime.now();
    final cashIn = cashInWindow(
      SaleHistoryService.instance.sales,
      outletId: open.outletId,
      from: open.openedAt,
      to: now,
    );
    final cashOut = cashExpensesInWindow(
      ExpenseService.instance.expenses,
      outletId: open.outletId,
      from: open.openedAt,
      to: now,
    );
    final expected = expectedCash(
      openingFloat: open.openingFloat,
      cashIn: cashIn,
      cashExpenses: cashOut,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Shift terbuka',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: SukaTeaColors.emerald,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'OPEN',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _shiftRow(
              'Dibuka oleh',
              open.cashierName.isEmpty ? 'Kasir' : open.cashierName,
            ),
            _shiftRow('Dibuka', formatShiftTime(open.openedAt)),
            _shiftRow('Modal awal', formatRupiah(open.openingFloat)),
            _shiftRow('Tunai masuk', formatRupiah(cashIn)),
            _shiftRow('Pengeluaran tunai', '-${formatRupiah(cashOut)}'),
            const Divider(height: 24),
            _shiftRow(
              'Expected sejauh ini',
              formatRupiah(expected),
              bold: true,
            ),
            const SizedBox(height: 12),
            TapFeedback(
              child: FilledButton(
                onPressed: () => _closeShift(open),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 56),
                ),
                child: const Text('Tutup Kas'),
              ),
            ),
            ..._closedHistory(),
          ],
        ),
      ),
    );
  }

  /// Riwayat shift closed gerai aktif, terbaru dulu (maks 5).
  /// Selisih hijau bila pas, merah bila ada selisih.
  List<Widget> _closedHistory() {
    final closed =
        CashShiftService.instance.closedShifts().take(5).toList();
    if (closed.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      const Text(
        'Riwayat shift (gerai ini)',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      for (final s in closed) _closedShiftRow(s),
    ];
  }

  Widget _closedShiftRow(CashShift s) {
    final diff = s.difference ?? 0;
    final closedAt = s.closedAt;
    final when = closedAt == null
        ? formatShiftDayTime(s.openedAt)
        : '${formatShiftDayTime(s.openedAt)} – ${formatShiftTime(closedAt)}';
    final opener = s.cashierName.isEmpty ? 'Kasir' : s.cashierName;
    final closer = s.closedByCashierName;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                when,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                formatRupiah(diff),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: diff == 0
                      ? SukaTeaColors.emeraldDark
                      : SukaTeaColors.danger,
                ),
              ),
            ],
          ),
          Text(
            '$opener • Dihitung ${formatRupiah(s.countedCash ?? 0)}'
            ' / Expected ${formatRupiah(s.expectedCash ?? 0)}'
            '${closer.isEmpty ? '' : ' • Ditutup $closer'}',
            style: const TextStyle(color: SukaTeaColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _shiftRow(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    String label,
    int amount, {
    bool isCount = false,
    String suffix = '',
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(
              isCount ? '$amount$suffix' : formatRupiah(amount),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
