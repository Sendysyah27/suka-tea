import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../data/models.dart';
import '../../data/sale_history.dart';
import '../../data/sheets_export.dart';
import '../riwayat/riwayat_page.dart';

/// Laporan & Tutup Kasir — rekap per cara bayar + rekonsiliasi kas tunai
/// + export ke Google Sheets (Edge Function, Owner saja). Desain v2:
/// kartu radius 20, tombol 56px.
///
/// DATA NYATA dari riwayat penjualan hari ini: penjualan tunai, produk
/// terlaris (top 3), dan tombol ke Riwayat. Modal awal laci diisi kasir
/// (bukan angka contoh). Bila belum ada transaksi hari ini, tampil
/// state kosong yang jujur.
class LaporanPage extends StatefulWidget {
  const LaporanPage({super.key});

  @override
  State<LaporanPage> createState() => _LaporanPageState();
}

class _LaporanPageState extends State<LaporanPage> {
  final _openingController = TextEditingController();
  final _countedController = TextEditingController();
  int? _selisih;

  int get _openingCash => int.tryParse(_openingController.text) ?? 0;

  void _hitungSelisih(int tunaiSales) {
    final counted = int.tryParse(_countedController.text);
    if (counted == null) return;
    setState(() => _selisih = counted - (_openingCash + tunaiSales));
  }

  @override
  void dispose() {
    _openingController.dispose();
    _countedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SaleHistoryService.instance,
      builder: (context, _) {
        final today = SaleHistoryService.instance.salesOn(DateTime.now());
        final tunaiSales = today
            .where((s) => s.method == PaymentMethod.tunai)
            .fold(0, (sum, s) => sum + s.total);
        final top = topProducts(today);
        final expected = _openingCash + tunaiSales;
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
                      'Tutup Kasir — hari ini',
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
            TextField(
              controller: _openingController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Modal awal laci (Rp)',
              ),
              onChanged: (_) => setState(() => _selisih = null),
            ),
            const SizedBox(height: 12),
            _row('Kas yang seharusnya ada', expected),
            const SizedBox(height: 12),
            TextField(
              controller: _countedController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Hitung kas tunai di laci (Rp)',
                hintText: 'Masukkan hasil hitungan…',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _hitungSelisih(tunaiSales),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 56),
                    ),
                    icon: SvgPicture.asset(
                      AppIcons.tutupKasir,
                      width: 20,
                      height: 20,
                      colorFilter: const ColorFilter.mode(
                        SukaTeaColors.emerald,
                        BlendMode.srcIn,
                      ),
                    ),
                    label: const Text('Hitung Selisih'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RiwayatPage(),
                        ),
                      );
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 56),
                    ),
                    child: const Text('Lihat Riwayat'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Export Sheets bukan bagian frame FigCraft 07, tapi
            // fungsinya dipertahankan (bukan dihapus): tombol
            // outline full-width di bawah baris utama.
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final ok =
                      await exportShiftToSheets(shiftId: 'demo-shift');
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok
                          ? 'Export Sheets terkirim.'
                          : 'Export Sheets belum tersedia (Supabase/secret belum dikonfigurasi).'),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 56),
                ),
                icon: const Icon(Icons.table_chart),
                label: const Text('Export Sheets'),
              ),
            ),
            if (_selisih != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Selisih kas',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              formatRupiah(_selisih!),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                                color: _selisih == 0
                                    ? SukaTeaColors.emeraldDark
                                    : SukaTeaColors.danger,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _selisih == 0
                              ? 'Pas — tidak ada selisih.'
                              : 'Ada selisih — cek kembali hitungan laci.',
                          style: const TextStyle(color: SukaTeaColors.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
