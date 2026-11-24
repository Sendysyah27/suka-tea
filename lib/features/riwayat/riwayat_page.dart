import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/models.dart';
import '../../data/sale_history.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import '../../data/topping_service.dart';
import '../kasir/receipt.dart';

/// Riwayat transaksi — daftar penjualan selesai, terbaru dulu.
/// Tap satu transaksi = buka lagi struknya (halaman penuh).
/// Dibuka dari tab Laporan ("Lihat Riwayat") dan dari Pantau Gerai
/// ("Lihat semua transaksi (N)").
/// [outletId] (Batch C5): bila diisi, hanya transaksi gerai itu yang
/// tampil; null = semua gerai (perilaku lama dari Laporan).
/// Void (Batch C1): HANYA Owner (tombol ⋮ di kartu, konfirmasi dulu).
/// Void mengembalikan stok bahan (termasuk topping) dan transaksi
/// tidak lagi dihitung di omzet/Keuangan/Laporan — tapi tetap tampil
/// di sini dengan label VOID.
/// Batch C9: StatefulWidget — buka halaman menarik semua data gerai
/// dari server (refreshSales) + tombol refresh di AppBar; penjualan
/// HP lain muncul di sini dalam hitungan detik (timer 10 detik).
class RiwayatPage extends StatefulWidget {
  const RiwayatPage({super.key, required this.role, this.outletId});

  final AppRole role;

  final String? outletId;

  @override
  State<RiwayatPage> createState() => _RiwayatPageState();
}

class _RiwayatPageState extends State<RiwayatPage> {
  /// true = tombol refresh manual sedang menarik data.
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // Tarik semua data gerai ini — penjualan HP lain bisa sudah
    // masuk server sejak halaman ini terakhir dibuka.
    unawaited(SyncService.instance.refreshSales());
  }

  /// Tarik ulang semua data gerai ini dari server SEKARANG (Batch
  /// C9). Snackbar jujur: sukses hanya bila lastPullAt benar-benar
  /// berubah (offline = gagal, bukan "disegarkan").
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final before = SyncService.instance.lastPullAt;
    await SyncService.instance.refreshSales();
    if (!mounted) return;
    setState(() => _refreshing = false);
    final after = SyncService.instance.lastPullAt;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          after != null && after != before
              ? 'Data disegarkan dari server.'
              : 'Gagal menyegarkan — periksa koneksi, coba lagi.',
        ),
      ),
    );
  }

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
    // Batch C6: mutasi stok void ditautkan ke client_uuid penjualan
    // asal (sale.id) supaya server bisa menautkannya; sesudah void,
    // sync fire-and-forget (event void diantrekan di voidSale).
    await StockService.instance.restoreForSale(
      cartItems,
      transactionClientUuid: sale.id,
    );
    await SaleHistoryService.instance.voidSale(sale.id);
    unawaited(SyncService.instance.syncNow());
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
      appBar: AppBar(
        title: const ScreenTitle('Riwayat Transaksi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            tooltip: 'Segarkan dari server',
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: SaleHistoryService.instance,
        builder: (context, _) {
          final allSales = SaleHistoryService.instance.sales;
          final sales = widget.outletId == null
              ? allSales
              : allSales.where((s) => s.outletId == widget.outletId).toList();
          if (sales.isEmpty) {
            return Center(
              child: Text(
                widget.outletId == null
                    ? 'Belum ada transaksi.\nPenjualan yang sudah dibayar muncul di sini.'
                    : 'Belum ada transaksi di gerai ini.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: SukaTeaColors.muted),
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
                          cashier: sale.displayCashierName,
                          time: sale.createdAt,
                          discount: sale.discount,
                          isVoid: sale.isVoid,
                          qrisAmount: sale.qrisAmount,
                          cashAmount: sale.cashAmount,
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
                            if (widget.role.canVoidSale && !sale.isVoid)
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
                        const SizedBox(height: 4),
                        // Nama kasir pencatat (Batch C8.2 WS4) —
                        // dari sesi/server, bukan hardcode 'Kasir'.
                        Text(
                          'Kasir: ${sale.displayCashierName}',
                          style: const TextStyle(
                            color: SukaTeaColors.muted,
                            fontSize: 12,
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
