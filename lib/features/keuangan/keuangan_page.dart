import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../data/models.dart';
import '../../data/sale_history.dart';
import '../../data/stock_service.dart';

/// Keuangan — HANYA Owner. Desain v2: hero card emerald gelap untuk
/// omzet + laba, lalu rincian per cara bayar.
///
/// DATA NYATA dari riwayat penjualan hari ini (bukan lagi angka contoh):
/// omzet, jumlah transaksi, jumlah cup, rata-rata per transaksi, dan
/// HPP + laba ESTIMASI (resep x harga bahan yang diatur Owner di tab
/// Stok — bukan lagi estimasi pasar). Pengeluaran harian belum dicatat
/// di app, jadi belum dikurangi dari laba.
class KeuanganPage extends StatelessWidget {
  const KeuanganPage({super.key, required this.role});

  final AppRole role;

  @override
  Widget build(BuildContext context) {
    if (!role.canViewProfit) {
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
      listenable: Listenable.merge([
        SaleHistoryService.instance,
        StockService.instance,
      ]),
      builder: (context, _) {
        // Transaksi void DIKECUALIKAN (Batch C1): omzet, laba, dan
        // rincian tidak menghitung transaksi yang sudah di-void.
        final today =
            SaleHistoryService.instance.activeSalesOn(DateTime.now());
        if (today.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Belum ada transaksi hari ini.\n'
                'Omzet, laba, dan rincian muncul setelah ada penjualan.',
                textAlign: TextAlign.center,
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            ),
          );
        }
        // HPP dari harga bahan yang diatur Owner di tab Stok
        // (Batch C1b) — bukan lagi const estimasi di seed_menu.
        final stats = computeDailyStats(
          today,
          StockService.instance.recipes,
          StockService.instance.costsByName,
        );
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
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
                        formatRupiah(stats.labaEstimate),
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
                  dotColor:
                      m.isCashless ? SukaTeaColors.cashless : SukaTeaColors.cash,
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
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'HPP dihitung dari resep x harga bahan yang diatur Owner '
                'di tab Stok. Pengeluaran harian belum dicatat, jadi belum '
                'dikurangi dari laba.',
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            ),
          ],
        );
      },
    );
  }

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
