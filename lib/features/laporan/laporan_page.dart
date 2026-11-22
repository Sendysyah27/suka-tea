import 'package:flutter/material.dart';

import '../../core/utils/money.dart';
import '../../data/sheets_export.dart';

/// Laporan & Tutup Kasir — rekap per cara bayar + rekonsiliasi kas tunai
/// + export ke Google Sheets (Edge Function, Owner saja).
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
          child: ListTile(
            title: Text('Tutup Kasir — hari ini (contoh)'),
            subtitle: Text('Rekap per cara bayar + rekonsiliasi kas tunai.'),
          ),
        ),
        const SizedBox(height: 8),
        _row('Modal awal laci', openingCash),
        _row('Penjualan tunai', tunaiSales),
        _row('Kas yang seharusnya ada', openingCash + tunaiSales),
        const SizedBox(height: 8),
        TextField(
          controller: _countedController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Hitung kas tunai di laci (Rp)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _hitungSelisih,
                child: const Text('Hitung Selisih'),
              ),
            ),
            const SizedBox(width: 8),
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
              child: ListTile(
                title: const Text('Selisih kas'),
                trailing: Text(
                  formatRupiah(_selisih!),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _selisih == 0 ? Colors.green : Colors.red,
                  ),
                ),
                subtitle: Text(_selisih == 0
                    ? 'Pas — tidak ada selisih.'
                    : 'Ada selisih — cek kembali hitungan laci.'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _row(String label, int amount) {
    return Card(
      child: ListTile(
        title: Text(label),
        trailing: Text(formatRupiah(amount)),
      ),
    );
  }
}
