import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/models.dart';
import '../../data/outlet_service.dart';
import '../../data/sale_history.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import '../riwayat/riwayat_page.dart';
import 'gerai_edit_page.dart';

/// Pantau Gerai (Batch C4, FigCraft v29 frame 15): transaksi berjalan,
/// stok menipis, laporan Harian/Bulanan + top-3 produk — per gerai.
///
/// DATA JUJUR: stok di app ini SATU untuk semua gerai (StockService
/// tidak per-gerai — belum ada pemisahan stok per outlet di Drift).
/// Jadi bagian "Stok menipis" menampilkan stok HP ini dan hanya
/// bermakna untuk gerai yang sedang dibuka; untuk gerai lain tampil
/// catatan. Transaksi + laporan per gerai BENAR-BENAR per gerai
/// (SaleHistory.outletId, Batch C4). Batch C6: transaksi + laporan
/// kini bisa LIVE dari Supabase (pull di halaman ini, fallback data
/// lokal bila offline/gagal) — gerai lain pun tampil penuh.
class GeraiMonitorPage extends StatefulWidget {
  const GeraiMonitorPage({super.key, required this.outlet});

  final Outlet outlet;

  @override
  State<GeraiMonitorPage> createState() => _GeraiMonitorPageState();
}

class _GeraiMonitorPageState extends State<GeraiMonitorPage> {
  var _monthly = false;

  /// Transaksi LIVE dari Supabase (null = belum berhasil pull —
  /// pakai data lokal). Pull sebulan penuh supaya Harian + Bulanan
  /// sama-sama bisa dihitung dari data live.
  List<SaleRecord>? _liveSales;
  var _liveLoading = false;
  String? _liveError;

  @override
  void initState() {
    super.initState();
    _refreshLive();
  }

  /// Tarik transaksi gerai dari Supabase (dipanggil initState +
  /// tombol refresh). Gagal (offline / Supabase belum dikonfigurasi
  /// / EF belum di-deploy) = tetap tampil data lokal, bukan error
  /// merah — halaman ini harus tetap berguna saat offline.
  Future<void> _refreshLive() async {
    if (_liveLoading) return;
    setState(() => _liveLoading = true);
    unawaited(SyncService.instance.refreshPending());
    try {
      final now = DateTime.now();
      final sales = await SyncService.instance.pullOutlet(
        outletId: widget.outlet.id,
        from: DateTime(now.year, now.month, 1),
        to: now,
      );
      if (!mounted) return;
      setState(() {
        _liveSales = sales;
        _liveError = null;
        _liveLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _liveSales = null;
        _liveError = e.toString();
        _liveLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final outlet = widget.outlet;
    final isCurrent =
        outlet.id == OutletService.instance.currentOutletId;
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: ScreenTitle(outlet.name),
        actions: [
          IconButton(
            tooltip: 'Muat ulang data live',
            onPressed: _refreshLive,
            icon: const Icon(Icons.refresh_outlined),
          ),
          IconButton(
            tooltip: 'Ubah gerai',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => GeraiEditPage(outlet: outlet),
              ),
            ),
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          SaleHistoryService.instance,
          StockService.instance,
          SyncService.instance,
        ]),
        builder: (context, _) {
          // Batch C6: bila pull live berhasil, transaksi + laporan
          // memakai data Supabase (semua gerai, bukan cuma HP ini);
          // bila gagal/offline, jatuh ke data lokal seperti dulu.
          // Void tetap dikecualikan (sama seperti activeSalesOn).
          final List<SaleRecord> todaySales;
          final List<SaleRecord> periodSales;
          if (_liveSales != null) {
            final live = _liveSales!.where((s) => !s.isVoid).toList();
            todaySales = live
                .where(
                  (s) =>
                      s.createdAt.year == now.year &&
                      s.createdAt.month == now.month &&
                      s.createdAt.day == now.day,
                )
                .toList();
            periodSales = _monthly
                ? live
                    .where(
                      (s) =>
                          s.createdAt.year == now.year &&
                          s.createdAt.month == now.month,
                    )
                    .toList()
                : todaySales;
          } else {
            todaySales = SaleHistoryService.instance.activeSalesOn(
              now,
              outletId: outlet.id,
            );
            periodSales = _monthly
                ? SaleHistoryService.instance.salesInMonth(
                    now,
                    outletId: outlet.id,
                  )
                : todaySales;
          }
          final stats = computeDailyStats(
            periodSales,
            StockService.instance.recipes,
            StockService.instance.costsByName,
          );
          final top = topProducts(periodSales);
          final lowStock = StockService.instance.levels
              .where((s) => s.isLow)
              .toList();
          final timeLabel =
              '${now.hour.toString().padLeft(2, '0')}:'
              '${now.minute.toString().padLeft(2, '0')}';
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? SukaTeaColors.emerald
                          : SukaTeaColors.border,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      isCurrent ? '● LIVE' : 'BUKAN GERAI INI',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _liveLoading
                          ? 'memuat data live…'
                          : _liveSales != null
                              ? 'update $timeLabel • Live Supabase'
                              : 'update $timeLabel • data lokal',
                      style: const TextStyle(
                        color: SukaTeaColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              // Batch C6: hitungan antrean belum tersinkron (satu
              // tempat saja — di sini, bukan di Laporan). Hilang
              // sendiri sesudah sync berhasil.
              if (SyncService.instance.pendingCount > 0) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDF3E0),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${SyncService.instance.pendingCount} transaksi '
                    'belum tersinkron ke Supabase',
                    style: const TextStyle(
                      color: SukaTeaColors.amber,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              if (_liveSales == null &&
                  _liveError != null &&
                  SyncService.instance.isConfigured) ...[
                const SizedBox(height: 8),
                const _NoteCard(
                  text: 'Data live gagal dimuat — menampilkan data lokal '
                      'dari HP ini.',
                ),
              ],
              if (!isCurrent) ...[
                const SizedBox(height: 12),
                _NoteCard(
                  text: _liveSales != null
                      ? 'Gerai ini tidak sedang dibuka di HP ini — tapi '
                          'transaksi & laporan di bawah diambil LIVE dari '
                          'Supabase, jadi tampil penuh. Stok masih dari '
                          'HP ini: stok per gerai belum dipisah.'
                      : 'Gerai ini tidak sedang dibuka di HP ini. '
                          'Transaksi & laporan di bawah hanya dari penjualan '
                          'yang tercatat di HP ini — data gerai lain tampil '
                          'penuh setelah sinkronisasi Supabase aktif.',
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'Transaksi berjalan',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 8),
              if (todaySales.isEmpty)
                const Text(
                  'Belum ada transaksi hari ini di gerai ini.',
                  style: TextStyle(color: SukaTeaColors.muted),
                )
              else ...[
                // Batch C5 (perintah Sendy 23 Nov 21:29): maks 3
                // transaksi terbaru di sini; total transaksi ketuk
                // tombol di bawah → daftar lengkap gerai ini
                // (RiwayatPage dengan filter outletId).
                for (final sale in todaySales.take(3))
                  Card(
                    child: ListTile(
                      title: Text(
                        '${sale.cups} cup • ${sale.method.label}',
                      ),
                      subtitle: Text(
                        '${sale.createdAt.hour.toString().padLeft(2, '0')}:'
                        '${sale.createdAt.minute.toString().padLeft(2, '0')}'
                        ' • ${sale.items.map((i) => i.productName).join(', ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        formatRupiah(sale.total),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                if (todaySales.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RiwayatPage(
                            role: AppRole.owner,
                            outletId: outlet.id,
                          ),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(
                        'Lihat semua transaksi (${todaySales.length})',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              const Text(
                'Stok menipis',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 8),
              if (!isCurrent)
                const _NoteCard(
                  text: 'Stok di HP ini adalah stok gerai yang sedang '
                      'dibuka — stok per gerai belum dipisah. Buka gerai '
                      'ini sebagai kasir untuk melihat stoknya.',
                )
              else if (lowStock.isEmpty)
                const Text(
                  'Semua stok aman.',
                  style: TextStyle(color: SukaTeaColors.muted),
                )
              else
                for (final item in lowStock)
                  Card(
                    child: ListTile(
                      title: Text(item.name),
                      subtitle: Text(
                        'Sisa ${item.qty} ${item.unit}',
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFDF3E0),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Menipis',
                          style: TextStyle(
                            color: SukaTeaColors.amber,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
              const SizedBox(height: 16),
              const Text(
                'Laporan',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Harian')),
                  ButtonSegment(value: true, label: Text('Bulanan')),
                ],
                selected: {_monthly},
                onSelectionChanged: (set) =>
                    setState(() => _monthly = set.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _statCard('Omzet', formatRupiah(stats.omzet)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _statCard(
                      'Laba (estimasi)',
                      formatRupiah(stats.labaEstimate),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${stats.txnCount} transaksi • ${stats.cups} cup • '
                'HPP ${formatRupiah(stats.hppEstimate)} (estimasi)',
                style: const TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 16),
              const Text(
                'Produk terlaris',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 8),
              if (top.isEmpty)
                const Text(
                  'Belum ada penjualan di periode ini.',
                  style: TextStyle(color: SukaTeaColors.muted),
                )
              else
                for (var i = 0; i < top.length; i++)
                  Card(
                    child: ListTile(
                      leading: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      title: Text(top[i].name),
                      trailing: Text('${top[i].qty} cup'),
                    ),
                  ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: SukaTeaColors.leafBg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: const TextStyle(color: SukaTeaColors.muted, fontSize: 12),
        ),
      ),
    );
  }
}
