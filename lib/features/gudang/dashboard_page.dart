import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/brew_service.dart';
import '../../data/c10_models.dart';
import '../../data/expense_service.dart';
import '../../data/menu_service.dart';
import '../../data/outlet_service.dart';
import '../../data/package_service.dart';
import '../../data/sale_history.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import '../keuangan/keuangan_page.dart';
import '../laporan/laporan_page.dart';
import '../gerai/gerai_list_page.dart';
import '../riwayat/riwayat_page.dart';
import 'brew_page.dart';
import 'gudang_common.dart';
import 'ledger_page.dart';
import 'opname_page.dart';
import 'package_list_page.dart';
import 'send_stock_page.dart';
import 'stock_in_page.dart';

/// Dashboard Owner FULL (Batch C10 WS7, FigCraft v32 frame 17).
/// Owner-only. 9 seksi, urutan layar 1→2→4→3→5→6→7→8→9:
/// 1 Ringkasan hari ini semua gerai → Laporan.
/// 2 Perbandingan 4 gerai (rank #1–#4 by omzet) → Pantau Gerai.
/// 4 Target per gerai (progress + sisa; belum ada target = ajakan
///   atur) → dialog edit target.
/// 3 Tren 7 hari (omzet/hari + hari ini vs kemarin).
/// 5 Performa per kasir hari ini → Riwayat (filter kasir + hari).
/// 6 Stok (gudang menipis/habis; per gerai: 3 bahan paling tipis,
///   total cup bisa dijual, kiriman hari ini; selisih opname terakhir).
/// 7 Keuangan (HPP, pengeluaran, laba bersih) → Keuangan.
/// 8 Peringatan (gudang kurang untuk paket default; cup < 10;
///   opname negatif 2x dalam 7 hari; info Teh Masak sesudah 20:00;
///   kosong = "Semua aman"; peringatan merah juga banner di atas).
/// 9 Jalan pintas (Stok Masuk, Buat Paket, Kirim ke Gerai, Masak
///   Teh, Opname, Riwayat Keluar-Masuk).
///
/// Gerai yang belum pernah sync = "Belum ada data tersinkron"
/// (JANGAN tampilkan angka 0 seolah data). Semua angka dari data
/// gabungan C9 (pull-merge) — bukan data lokal satu HP saja.
class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.role,
    required this.onExitGerai,
  });

  /// Peran pemanggil (Owner — Dashboard hanya dibuka dari menu Owner).
  final AppRole role;

  /// Keluar gerai (diteruskan ke LaporanPage).
  final VoidCallback onExitGerai;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _refreshingAll = false;

  Future<void> _refreshAll() async {
    if (_refreshingAll) return;
    setState(() => _refreshingAll = true);
    await SyncService.instance.refreshAllOutlets();
    if (mounted) setState(() => _refreshingAll = false);
  }

  Future<void> _editTarget(String outletId, int currentOmzet) async {
    final ctrl = TextEditingController(
      text: PackageService.instance.targetFor(outletId) > 0
          ? PackageService.instance.targetFor(outletId).toString()
          : '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Target omzet — ${outletName(outletId)}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Realisasi hari ini: ${formatRupiah(currentOmzet)}',
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Target omzet harian (Rp)',
                hintText: 'kosong = tanpa target',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final target = int.tryParse(ctrl.text.trim()) ?? 0;
    if (target < 0) return;
    await PackageService.instance.setTarget(outletId, target);
    unawaited(SyncService.instance.syncNow());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            target == 0
                ? 'Target ${outletName(outletId)} dihapus.'
                : 'Target ${outletName(outletId)}: ${formatRupiah(target)}/hari.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const ScreenTitle('Dashboard Owner'),
        actions: [
          IconButton(
            onPressed: _refreshingAll ? null : _refreshAll,
            tooltip: 'Segarkan semua gerai',
            icon: _refreshingAll
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          SaleHistoryService.instance,
          ExpenseService.instance,
          StockService.instance,
          PackageService.instance,
          BrewService.instance,
          SyncService.instance,
          OutletService.instance,
          MenuService.instance,
        ]),
        builder: (context, _) {
          final outlets = OutletService.instance.outlets;
          final today = DateTime.now();
          final recipes = StockService.instance.recipes;

          // ---- Statistik per gerai hari ini (null = belum sync) ----
          final statsByOutlet = <String, DailyStats?>{};
          for (final o in outlets) {
            if (!SyncService.instance.hasSynced(o.id)) {
              statsByOutlet[o.id] = null;
              continue;
            }
            statsByOutlet[o.id] = computeDailyStats(
              SaleHistoryService.instance.activeSalesOn(today, outletId: o.id),
              recipes,
              StockService.instance.costsByNameFor(o.id),
            );
          }
          final syncedStats = statsByOutlet.values
              .whereType<DailyStats>()
              .toList();
          final totalOmzet =
              syncedStats.fold<int>(0, (s, x) => s + x.omzet);
          final totalTxn =
              syncedStats.fold<int>(0, (s, x) => s + x.txnCount);
          final totalCups =
              syncedStats.fold<int>(0, (s, x) => s + x.cups);
          final totalHpp =
              syncedStats.fold<int>(0, (s, x) => s + x.hppEstimate);
          var totalExpense = 0;
          for (final o in outlets) {
            if (!SyncService.instance.hasSynced(o.id)) continue;
            totalExpense += ExpenseService.instance
                .expensesOn(today, outletId: o.id)
                .fold<int>(0, (s, e) => s + e.amount);
          }
          final labaBersih = totalOmzet - totalHpp - totalExpense;
          // Batch C10.1 Bug 2b — HPP JUJUR (sama seperti Keuangan):
          // bila ada bahan resep produk aktif yang biayanya belum
          // diatur di SATU gerai tersinkron saja, HPP + laba bersih
          // halaman ini "belum diatur" (bukan Rp0 yang menyesatkan).
          final hppUnset = outlets
              .where((o) => SyncService.instance.hasSynced(o.id))
              .any((o) => StockService.instance.hasUnsetCostsFor(o.id));

          // ---- Tren 7 hari (semua gerai yang sudah sync) ----
          final trend = <int>[];
          for (var d = 6; d >= 0; d--) {
            final day = today.subtract(Duration(days: d));
            var omzet = 0;
            for (final o in outlets) {
              if (!SyncService.instance.hasSynced(o.id)) continue;
              omzet += computeDailyStats(
                SaleHistoryService.instance.activeSalesOn(day, outletId: o.id),
                recipes,
                StockService.instance.costsByNameFor(o.id),
              ).omzet;
            }
            trend.add(omzet);
          }
          final yesterdayOmzet = trend.length >= 2 ? trend[5] : 0;
          final todayVsYesterday = totalOmzet - yesterdayOmzet;

          // ---- Per kasir hari ini ----
          final byCashier = <String, _CashierDay>{};
          for (final o in outlets) {
            if (!SyncService.instance.hasSynced(o.id)) continue;
            for (final s in SaleHistoryService.instance
                .activeSalesOn(today, outletId: o.id)) {
              final name = s.displayCashierName;
              final entry = byCashier.putIfAbsent(
                name,
                () => _CashierDay(name: name, outletId: o.id),
              );
              entry.txnCount++;
              entry.omzet += s.total;
              entry.cups += s.cups;
            }
          }
          final cashiers = byCashier.values.toList()
            ..sort((a, b) => b.omzet.compareTo(a.omzet));

          // ---- Stok ----
          final gudangByName =
              StockService.instance.stockByNameFor(gudangOutletId);
          final gudangLow = gudangByName.values
              .where((s) => s.isLow)
              .toList()
            ..sort((a, b) => a.qty.compareTo(b.qty));
          final gudangEmpty =
              gudangByName.values.where((s) => s.qty <= 0).toList();

          // ---- Peringatan ----
          final warnings = <String>[];
          for (final o in outlets) {
            final defId = PackageService.instance.defaultPackageIdFor(o.id);
            if (defId == null) continue;
            final pkg = PackageService.instance.packageById(defId);
            if (pkg == null) continue;
            final items = [
              for (final it in pkg.items)
                if (it.qty > 0)
                  SendItem(stockName: it.stockName, qty: it.qty, unit: it.unit),
            ];
            final shortages = checkGudang(items, gudangByName);
            if (shortages.isNotEmpty) {
              warnings.add(
                'Gudang kurang untuk paket default ${outletName(o.id)} '
                '(${pkg.name}): ${shortages.map((s) => s.stockName).join(', ')}.',
              );
            }
          }
          for (final o in outlets) {
            final capacity = totalCapacityCups(
              MenuService.instance.products,
              recipes,
              StockService.instance.stockByNameFor(o.id),
            );
            if (SyncService.instance.hasSynced(o.id) && capacity < 10) {
              warnings.add(
                '${outletName(o.id)} hanya bisa jual $capacity cup lagi.',
              );
            }
          }
          for (final o in outlets) {
            final recentNeg = PackageService.instance
                .opnamesFor(o.id)
                .where((op) =>
                    op.difference < 0 &&
                    today.difference(op.countedAt).inDays < 7)
                .toList();
            if (recentNeg.length >= 2) {
              warnings.add(
                '${outletName(o.id)}: selisih negatif ${recentNeg.length}x '
                'dalam 7 hari — cek opname.',
              );
            }
          }
          if (today.hour >= 20) {
            for (final o in outlets) {
              final masak = StockService.instance
                      .stockByNameFor(o.id)[tehMasakName]
                      ?.qty ??
                  0;
              if (masak > 0) {
                warnings.add(
                  'Sisa Teh Masak ${outletName(o.id)} ${qtyText(masak)} L '
                  'akan terbuang malam ini.',
                );
              }
            }
          }
          final failedNotices = PackageService.instance.failedNotices;
          for (final n in failedNotices) {
            warnings.add(
              'Kiriman ke ${outletName(n.outletId)} gagal — ${n.message}',
            );
          }

          // Rank gerai by omzet (yang sudah sync saja).
          final ranked = outlets
              .where((o) => statsByOutlet[o.id] != null)
              .toList()
            ..sort((a, b) => statsByOutlet[b.id]!
                .omzet
                .compareTo(statsByOutlet[a.id]!.omzet));

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (warnings.isNotEmpty)
                Card(
                  color: SukaTeaColors.deleteBg,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Peringatan',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: SukaTeaColors.danger,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (final w in warnings)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              '• $w',
                              style: const TextStyle(
                                color: SukaTeaColors.danger,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // ---- §1 Ringkasan hari ini ----
              _SectionCard(
                title: 'Ringkasan hari ini — semua gerai',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LaporanPage(
                      role: widget.role,
                      onExitGerai: widget.onExitGerai,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      formatRupiah(totalOmzet),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: SukaTeaColors.emeraldDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$totalTxn transaksi • $totalCups cup • '
                      'laba bersih ${formatRupiah(labaBersih)}',
                      style: const TextStyle(color: SukaTeaColors.muted),
                    ),
                    if (statsByOutlet.values.any((s) => s == null))
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Sebagian gerai belum tersinkron — angka di '
                          'atas hanya dari gerai yang sudah sync.',
                          style: TextStyle(
                            color: SukaTeaColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // ---- §2 Perbandingan gerai ----
              _SectionCard(
                title: 'Perbandingan gerai hari ini',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const GeraiListPage(),
                  ),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < outlets.length; i++)
                      _GeraiRow(
                        rank: ranked.contains(outlets[i])
                            ? ranked.indexOf(outlets[i]) + 1
                            : null,
                        name: outletName(outlets[i].id),
                        stats: statsByOutlet[outlets[i].id],
                      ),
                  ],
                ),
              ),
              // ---- §4 Target per gerai ----
              _SectionCard(
                title: 'Target omzet hari ini',
                child: Column(
                  children: [
                    for (final o in outlets)
                      _TargetRow(
                        outletId: o.id,
                        omzet: statsByOutlet[o.id]?.omzet ?? 0,
                        synced: statsByOutlet[o.id] != null,
                        onTap: () => _editTarget(
                          o.id,
                          statsByOutlet[o.id]?.omzet ?? 0,
                        ),
                      ),
                  ],
                ),
              ),
              // ---- §3 Tren 7 hari ----
              _SectionCard(
                title: 'Tren 7 hari',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hari ini vs kemarin: '
                      '${todayVsYesterday >= 0 ? '+' : ''}'
                      '${formatRupiah(todayVsYesterday)}'
                      '${yesterdayOmzet > 0 ? ' (${((todayVsYesterday / yesterdayOmzet) * 100).round()}%)' : ''}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: todayVsYesterday >= 0
                            ? SukaTeaColors.emeraldDark
                            : SukaTeaColors.danger,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _TrendBars(values: trend),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (var d = 6; d >= 0; d--)
                          Text(
                            _shortDay(today.subtract(Duration(days: d))),
                            style: const TextStyle(
                              color: SukaTeaColors.muted,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // ---- §5 Per kasir ----
              _SectionCard(
                title: 'Performa kasir hari ini',
                child: cashiers.isEmpty
                    ? const Text(
                        'Belum ada penjualan hari ini.',
                        style: TextStyle(color: SukaTeaColors.muted),
                      )
                    : Column(
                        children: [
                          for (final c in cashiers)
                            InkWell(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => RiwayatPage(
                                    role: widget.role,
                                    outletId: c.outletId,
                                    cashierName: c.name,
                                    day: today,
                                  ),
                                ),
                              ),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${c.name} • ${outletName(c.outletId)}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${c.txnCount} trx • ${c.cups} cup • '
                                      '${formatRupiah(c.omzet)}',
                                      style: const TextStyle(
                                        color: SukaTeaColors.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              // ---- §6 Stok ----
              _SectionCard(
                title: 'Stok',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (gudangEmpty.isNotEmpty)
                      Text(
                        'Gudang habis: ${gudangEmpty.map((s) => s.name).join(', ')}.',
                        style: const TextStyle(
                          color: SukaTeaColors.danger,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    if (gudangLow.isNotEmpty)
                      Text(
                        'Gudang menipis: ${gudangLow.map((s) => '${s.name} ${qtyText(s.qty)} ${s.unit}').join(', ')}.',
                        style: const TextStyle(
                          color: SukaTeaColors.amber,
                        ),
                      ),
                    if (gudangLow.isEmpty && gudangEmpty.isEmpty)
                      const Text(
                        'Gudang aman.',
                        style: TextStyle(color: SukaTeaColors.muted),
                      ),
                    const SizedBox(height: 8),
                    for (final o in outlets)
                      _GeraiStockRow(outletId: o.id),
                  ],
                ),
              ),
              // ---- §7 Keuangan ----
              _SectionCard(
                title: 'Keuangan hari ini',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => KeuanganPage(role: widget.role),
                  ),
                ),
                child: Column(
                  children: [
                    GudangRow(label: 'Omzet', value: formatRupiah(totalOmzet)),
                    GudangRow(
                      label: 'HPP (estimasi)',
                      // Batch C10.1 Bug 2b: biaya belum diatur ->
                      // "belum diatur", bukan Rp0.
                      value:
                          hppUnset ? 'belum diatur' : formatRupiah(totalHpp),
                    ),
                    GudangRow(
                      label: 'Pengeluaran',
                      value: formatRupiah(totalExpense),
                    ),
                    GudangRow(
                      label: 'Laba bersih',
                      value: hppUnset ? '—' : formatRupiah(labaBersih),
                      valueColor: hppUnset
                          ? null
                          : (labaBersih < 0
                              ? SukaTeaColors.danger
                              : SukaTeaColors.emeraldDark),
                    ),
                  ],
                ),
              ),
              // ---- §8 Peringatan ----
              _SectionCard(
                title: 'Peringatan',
                child: warnings.isEmpty
                    ? const Text(
                        'Semua aman.',
                        style: TextStyle(color: SukaTeaColors.muted),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final w in warnings)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                '• $w',
                                style: const TextStyle(
                                  color: SukaTeaColors.danger,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              // ---- §9 Jalan pintas ----
              _SectionCard(
                title: 'Jalan pintas',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ShortcutChip(
                      label: 'Stok Masuk',
                      icon: Icons.inventory_2,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const StockInPage(),
                        ),
                      ),
                    ),
                    _ShortcutChip(
                      label: 'Buat Paket',
                      icon: Icons.inventory,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PackageListPage(),
                        ),
                      ),
                    ),
                    _ShortcutChip(
                      label: 'Kirim ke Gerai',
                      icon: Icons.local_shipping,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SendStockPage(),
                        ),
                      ),
                    ),
                    _ShortcutChip(
                      label: 'Masak Teh',
                      icon: Icons.local_cafe,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const BrewPage(),
                        ),
                      ),
                    ),
                    _ShortcutChip(
                      label: 'Opname',
                      icon: Icons.fact_check,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const OpnamePage(),
                        ),
                      ),
                    ),
                    _ShortcutChip(
                      label: 'Riwayat Keluar-Masuk',
                      icon: Icons.swap_horiz,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LedgerPage(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }

  String _shortDay(DateTime d) {
    const days = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab'];
    return days[d.weekday % 7];
  }
}

class _CashierDay {
  _CashierDay({required this.name, required this.outletId});

  final String name;
  final String outletId;
  var txnCount = 0;
  var omzet = 0;
  var cups = 0;
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.onTap,
  });

  final String title;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GudangSectionTitle(title, onTap: onTap),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _GeraiRow extends StatelessWidget {
  const _GeraiRow({
    required this.rank,
    required this.name,
    required this.stats,
  });

  final int? rank;
  final String name;
  final DailyStats? stats;

  @override
  Widget build(BuildContext context) {
    // Lokal (bukan field) supaya promotion null-safety jalan di
    // rantai if/else di bawah — field widget tidak dipromosikan.
    final s = stats;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (rank != null)
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: rank == 1
                    ? SukaTeaColors.emerald
                    : SukaTeaColors.emeraldSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '#$rank',
                style: TextStyle(
                  color: rank == 1
                      ? Colors.white
                      : SukaTeaColors.emeraldDark,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            )
          else
            const SizedBox(width: 28),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (s == null)
            const Text(
              'Belum ada data tersinkron',
              style: TextStyle(color: SukaTeaColors.muted, fontSize: 12),
            )
          else if (s.txnCount == 0)
            const Text(
              'Belum ada penjualan hari ini',
              style: TextStyle(color: SukaTeaColors.muted, fontSize: 12),
            )
          else
            Text(
              '${formatRupiah(s.omzet)} • ${s.txnCount} trx • '
              '${s.cups} cup',
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
        ],
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.outletId,
    required this.omzet,
    required this.synced,
    required this.onTap,
  });

  final String outletId;
  final int omzet;
  final bool synced;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final target = PackageService.instance.targetFor(outletId);
    final pct = target > 0 ? (omzet / target).clamp(0.0, 1.0) : 0.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    outletName(outletId),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  !synced
                      ? 'Belum ada data tersinkron'
                      : target <= 0
                          ? 'Belum ada target — ketuk untuk atur'
                          : '${formatRupiah(omzet)} / ${formatRupiah(target)} '
                              '(${(pct * 100).round()}%)',
                  style: const TextStyle(color: SukaTeaColors.muted),
                ),
              ],
            ),
            if (target > 0) ...[
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: pct,
                backgroundColor: SukaTeaColors.border,
                color: SukaTeaColors.emerald,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrendBars extends StatelessWidget {
  const _TrendBars({required this.values});

  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final max = values.fold<int>(0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: 80,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Container(
                  height: max > 0 ? (v / max * 72).clamp(4.0, 72.0) : 4,
                  decoration: BoxDecoration(
                    color: v == values.last
                        ? SukaTeaColors.emerald
                        : SukaTeaColors.mint,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GeraiStockRow extends StatelessWidget {
  const _GeraiStockRow({required this.outletId});

  final String outletId;

  @override
  Widget build(BuildContext context) {
    final levels = StockService.instance.levelsFor(outletId);
    final low = levels.where((s) => s.isLow).toList()
      ..sort((a, b) => (a.qty / (a.lowThreshold == 0 ? 1 : a.lowThreshold))
          .compareTo(
              b.qty / (b.lowThreshold == 0 ? 1 : b.lowThreshold)));
    final top3 = low.take(3).toList();
    final capacity = totalCapacityCups(
      MenuService.instance.products,
      StockService.instance.recipes,
      StockService.instance.stockByNameFor(outletId),
    );
    final sendsToday = PackageService.instance.sendsFor(
      outletId,
      DateTime.now(),
    );
    final lastOpname =
        PackageService.instance.opnamesFor(outletId).firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  outletName(outletId),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                'Bisa jual $capacity cup',
                style: const TextStyle(color: SukaTeaColors.muted),
              ),
            ],
          ),
          if (top3.isNotEmpty)
            Text(
              'Paling tipis: ${top3.map((s) => '${s.name} ${qtyText(s.qty)} ${s.unit}').join(', ')}.',
              style: const TextStyle(
                color: SukaTeaColors.muted,
                fontSize: 12,
              ),
            ),
          Text(
            sendsToday.isEmpty
                ? 'Belum ada kiriman hari ini.'
                : 'Kiriman hari ini: ${sendsToday.length}x'
                    '${sendsToday.isNotEmpty ? ' (terakhir ${sendsToday.first.sentAt.hour.toString().padLeft(2, '0')}:${sendsToday.first.sentAt.minute.toString().padLeft(2, '0')})' : ''}.',
            style: const TextStyle(
              color: SukaTeaColors.muted,
              fontSize: 12,
            ),
          ),
          if (lastOpname != null)
            Text(
              lastOpname.difference == 0
                  ? 'Opname terakhir: cocok.'
                  : 'Opname terakhir: ${lastOpname.stockName} selisih '
                      '${lastOpname.difference > 0 ? '+' : ''}'
                      '${qtyText(lastOpname.difference)}.',
              style: TextStyle(
                color: lastOpname.difference == 0
                    ? SukaTeaColors.muted
                    : SukaTeaColors.danger,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}

class _ShortcutChip extends StatelessWidget {
  const _ShortcutChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18, color: SukaTeaColors.emeraldDark),
      label: Text(label),
      onPressed: onTap,
    );
  }
}
