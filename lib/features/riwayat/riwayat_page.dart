import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/models.dart';
import '../../data/sale_history.dart';
import '../../data/stock_service.dart';
import '../../data/topping_service.dart';
import '../kasir/receipt.dart';

/// Riwayat transaksi — daftar penjualan selesai, terbaru dulu.
/// Tap satu transaksi = buka lagi struknya (halaman penuh).
/// Dibuka dari tab Laporan ("Lihat Riwayat").
/// Void (Batch C1): HANYA Owner (tombol ⋮ di kartu, konfirmasi dulu).
/// Void mengembalikan stok bahan (termasuk topping) dan transaksi
/// tidak lagi dihitung di omzet/Keuangan/Laporan — tapi tetap tampil
/// di sini dengan label VOID.
class RiwayatPage extends StatelessWidget {
  const RiwayatPage({super.key, required this.role});

  final AppRole role;

  String _timeText(DateTime t) {
    return '${t.day}/${t.month}/${t.year} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  /// Konfirmasi + jalankan void: kembalikan stok dulu (restoreForSale),
  /// baru tandai record void. Stok dikembalikan dari item riwayat
  /// (SaleItem -> CartItem; topping dikenali dari nama).
  Future<void> _voidSale(BuildContext context, SaleRecord sale) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void transaksi ini?'),
        content: const Text(
          'Transaksi dibatalkan dan tidak dihitung di omzet. '
          'Stok bahan akan dikembalikan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: SukaTeaColors.danger,
            ),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final cartItems = sale.items
        .map((it) => it.toCartItem(ToppingService.instance.toppingNames))
        .toList();
    await StockService.instance.restoreForSale(cartItems);
    await SaleHistoryService.instance.voidSale(sale.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transaksi di-void, stok dikembalikan.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Riwayat Transaksi')),
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
                          discount: sale.discount,
                          isVoid: sale.isVoid,
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
                            // Pill VOID (merah) untuk transaksi yang
                            // sudah di-void — tetap tampil di riwayat.
                            if (sale.isVoid)
                              Container(
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: SukaTeaColors.danger,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Text(
                                  'VOID',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            // Pill metode outline (FigCraft frame 08)
                            // — bukan Chip tinted.
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: SukaTeaColors.border,
                                ),
                              ),
                              child: Text(
                                sale.method.label,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            // Aksi Void (HANYA Owner, belum void):
                            // menu ⋮ di kanan kartu.
                            if (role.canVoidSale && !sale.isVoid)
                              PopupMenuButton<String>(
                                tooltip: 'Aksi transaksi',
                                icon: const Icon(Icons.more_vert),
                                onSelected: (value) {
                                  if (value == 'void') {
                                    _voidSale(context, sale);
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'void',
                                    child: Text('Void transaksi'),
                                  ),
                                ],
                              ),
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
                              '${sale.cups} cup • ${sale.items.length} item'
                              '${sale.discount > 0 ? ' • Diskon -${formatRupiah(sale.discount)}' : ''}',
                              style: const TextStyle(
                                color: SukaTeaColors.muted,
                              ),
                            ),
                            Text(
                              formatRupiah(sale.total),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                                color: sale.isVoid
                                    ? SukaTeaColors.muted
                                    : SukaTeaColors.emerald,
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
