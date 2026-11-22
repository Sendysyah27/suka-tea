import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../data/sheets_export.dart';

/// Laporan & Tutup Kasir — rekap per cara bayar + rekonsiliasi kas tunai
/// + export ke Google Sheets (Edge Function, Owner saja). Desain v2:
/// kartu radius 20, tombol 56px.
class LaporanPage extends StatefulWidget {
  const LaporanPage({super.key});

  @override
  State<LaporanPage> createState() => _LaporanPageState();
}

class _LaporanPageState extends State<LaporanPage> {
  final _countedController = TextEditingController();
  int? _selisih;

  static const int openingCash = 50000;
  static const int tunaiSales = 125000;

  void _hitungSelisih() {
    final counted = int.tryParse(_countedController.text);
    if (counted == null) return;
    setState(() => _selisih = counted - (openingCash + tunaiSales));
  }

  @override
  void dispose() {
    _countedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                  'Tutup Kasir — hari ini (contoh)',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
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
        _row('Modal awal laci', openingCash),
        _row('Penjualan tunai', tunaiSales),
        _row('Kas yang seharusnya ada', openingCash + tunaiSales),
        const SizedBox(height: 12),
        TextField(
          controller: _countedController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Hitung kas tunai di laci (Rp)',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _hitungSelisih,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 56),
                ),
                child: const Text('Hitung Selisih'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () async {
                  final ok = await exportShiftToSheets(shiftId: 'demo-shift');
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok
                          ? 'Export Sheets terkirim.'
                          : 'Export Sheets belum tersedia (Supabase/secret belum dikonfigurasi).'),
                    ),
                  );
                },
                icon: const Icon(Icons.table_chart),
                label: const Text('Export Sheets'),
              ),
            ),
          ],
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
  }

  Widget _row(String label, int amount) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(
              formatRupiah(amount),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
