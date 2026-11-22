import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../data/models.dart';
import '../../data/sale_history.dart';
import '../kasir/receipt.dart';

/// Riwayat transaksi — daftar penjualan selesai, terbaru dulu.
/// Tap satu transaksi = buka lagi struknya (halaman penuh).
/// Dibuka dari tab Laporan ("Lihat Riwayat").
class RiwayatPage extends StatelessWidget {
  const RiwayatPage({super.key});

  String _timeText(DateTime t) {
    return '${t.day}/${t.month}/${t.year} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Riwayat Transaksi')),
      body: ListenableBuilder(
        listenable: SaleHistoryService.instance,
        builder: (context, _) {
          final sales = SaleHistoryService.instance.sales;
          if (sales.isEmpty) {
            return const Center(
              child: Text(
                'Belum ada transaksi.\nPenjualan yang sudah dibayar muncul di sini.',
                textAlign: TextAlign.center,
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: sales.length,
            itemBuilder: (context, i) {
              final sale = sales[i];
              final itemSummary = sale.items
                  .map((it) => '${it.qty}x ${it.productName}')
                  .join(', ');
              return Card(
                child: InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DigitalReceiptPage(
                          lines: sale.items
                              .map(
                                (it) => ReceiptLine(
                                  name:
                                      '${it.productName} ${it.variantName}',
                                  modifierText: it.modifiers.isEmpty
                                      ? ''
                                      : '(${it.modifiers.join(', ')})',
                                  qty: it.qty,
                                  unitPrice: it.unitPrice,
                                ),
                              )
                              .toList(),
                          method: sale.method,
                          total: sale.total,
                          paid: sale.paid,
                          cashier: 'Kasir',
                          time: sale.createdAt,
                        ),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _timeText(sale.createdAt),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Chip(label: Text(sale.method.label)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          itemSummary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: SukaTeaColors.muted,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${sale.cups} cup • ${sale.items.length} item',
                              style: const TextStyle(
                                color: SukaTeaColors.muted,
                              ),
                            ),
                            Text(
                              formatRupiah(sale.total),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
