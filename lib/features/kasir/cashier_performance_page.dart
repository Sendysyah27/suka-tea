import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../data/sale_history.dart';
import '../pin/pin_dialog.dart';
import '../riwayat/riwayat_page.dart';
import 'cashier_service.dart';
import 'kasir_management_page.dart';

/// Satu baris performa kasir (v40, frame 32).
typedef CashierPerformanceRow = ({
  String name,
  String outletId,
  int sales,
  int omzet,
  int cups,
  int voidCount,
  int discountCount,
});

/// Agregat performa per kasir dari penjualan lokal (SUDAH tersinkron
/// via pull — TIDAK ADA EF baru). [sales] = SEMUA record (termasuk
/// void) di jendela [from]..[to] (tanggal lokal, inklusif).
/// - jualan/omzet/cup: HANYA record non-void.
/// - void: jumlah record isVoid. diskon: jumlah record discount > 0.
/// - outletId baris = gerai penjualan TERBARU kasir itu (dipakai
/// ketuk baris → Riwayat).
/// Fungsi murni, di-test (angka demo frame 32 harus keluar dari sini).
({
  List<CashierPerformanceRow> rows,
  int totalSales,
  int totalOmzet,
  int totalVoid,
  int totalDiscount,
}) aggregateCashierPerformance(
  List<SaleRecord> sales,
  DateTime from,
  DateTime to,
) {
  final fromDay = DateTime(from.year, from.month, from.day);
  final toDay = DateTime(to.year, to.month, to.day);
  final byName = <String, _PerfAcc>{};
  for (final s in sales) {
    final day = DateTime(s.createdAt.year, s.createdAt.month, s.createdAt.day);
    if (day.isBefore(fromDay) || day.isAfter(toDay)) continue;
    final name = s.displayCashierName;
    final acc = byName.putIfAbsent(name, () => _PerfAcc(name: name));
    if (s.createdAt.isAfter(acc.latestAt)) {
      acc.latestAt = s.createdAt;
      acc.outletId = s.outletId;
    }
    if (s.isVoid) {
      acc.voidCount++;
      continue;
    }
    acc.sales++;
    acc.omzet += s.total;
    acc.cups += s.cups;
    if (s.discount > 0) acc.discountCount++;
  }
  final rows = byName.values
      .map(
        (a) => (
          name: a.name,
          outletId: a.outletId,
          sales: a.sales,
          omzet: a.omzet,
          cups: a.cups,
          voidCount: a.voidCount,
          discountCount: a.discountCount,
        ),
      )
      .toList()
    ..sort((a, b) => b.omzet.compareTo(a.omzet));
  var totalSales = 0;
  var totalOmzet = 0;
  var totalVoid = 0;
  var totalDiscount = 0;
  for (final r in rows) {
    totalSales += r.sales;
    totalOmzet += r.omzet;
    totalVoid += r.voidCount;
    totalDiscount += r.discountCount;
  }
  return (
    rows: rows,
    totalSales: totalSales,
    totalOmzet: totalOmzet,
    totalVoid: totalVoid,
    totalDiscount: totalDiscount,
  );
}

class _PerfAcc {
  _PerfAcc({required this.name});

  final String name;
  String outletId = '';
  DateTime latestAt = DateTime.fromMillisecondsSinceEpoch(0);
  var sales = 0;
  var omzet = 0;
  var cups = 0;
  var voidCount = 0;
  var discountCount = 0;
}

/// Performa Kasir (v40, frame 32) — Owner.
/// Data penjualan dari SaleHistory lokal (sudah tersinkron); status
/// aktif/resign kasir dari list-cashiers (PIN Owner sekali saat buka,
/// pola Kelola Kasir). Ketuk baris → Riwayat kasir itu HARI INI
/// (RiwayatPage hanya terima satu hari — keterbatasan yang dicatat
/// di brief v40 §5.8).
class CashierPerformancePage extends StatefulWidget {
  const CashierPerformancePage({super.key});

  @override
  State<CashierPerformancePage> createState() =>
      _CashierPerformancePageState();
}

class _CashierPerformancePageState extends State<CashierPerformancePage> {
  bool _sevenDays = false;
  List<Cashier>? _cashiers;
  String? _ownerPin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askOwnerPin());
  }

  Future<void> _askOwnerPin() async {
    String? ownerPin;
    final pinOk = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(
        onPinVerified: (pin) => ownerPin = pin,
      ),
    );
    if (pinOk != true || ownerPin == null || !mounted) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    _ownerPin = ownerPin!;
    final result = await CashierService.instance.listCashiers(
      ownerPin: _ownerPin!,
    );
    if (!mounted) return;
    if (result.ok) {
      setState(() => _cashiers = result.cashiers);
    }
    // Gagal muat daftar kasir BUKAN fatal — performa tetap tampil
    // dari penjualan lokal (tanpa catatan nonaktif/resign).
  }

  Cashier? _cashierFor(String name) {
    final list = _cashiers;
    if (list == null) return null;
    for (final c in list) {
      if (c.name == name) return c;
    }
    return null;
  }

  String _rangeText(DateTime from, DateTime to) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
      'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
    ];
    if (_sevenDays) {
      return '${from.day}–${to.day} ${months[to.month - 1]} ${to.year} '
          '· semua gerai';
    }
    return '${to.day} ${months[to.month - 1]} ${to.year} · semua gerai';
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final from = _sevenDays
        ? DateTime(today.year, today.month, today.day)
            .subtract(const Duration(days: 6))
        : DateTime(today.year, today.month, today.day);
    final to = DateTime(today.year, today.month, today.day);
    final agg = aggregateCashierPerformance(
      SaleHistoryService.instance.sales,
      from,
      to,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Performa Kasir',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              ChoiceChip(
                label: const Text('Hari ini'),
                selected: !_sevenDays,
                onSelected: (_) => setState(() => _sevenDays = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('7 hari'),
                selected: _sevenDays,
                onSelected: (_) => setState(() => _sevenDays = true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _rangeText(from, to),
                  style: const TextStyle(color: SukaTeaColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _sevenDays ? 'Total 7 hari' : 'Total hari ini',
                    style: const TextStyle(color: SukaTeaColors.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatRupiah(agg.totalOmzet),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 24,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${agg.totalSales} jualan · void ${agg.totalVoid} · '
                    'diskon ${agg.totalDiscount}',
                    style: const TextStyle(color: SukaTeaColors.muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (agg.rows.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Belum ada penjualan di jendela ini.',
                  style: TextStyle(color: SukaTeaColors.muted),
                ),
              ),
            )
          else
            for (final row in agg.rows) _performanceRow(row, today),
          const SizedBox(height: 12),
          const Text(
            'Ketuk kasir untuk lihat riwayatnya (filter kasir + hari).',
            style: TextStyle(color: SukaTeaColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _performanceRow(CashierPerformanceRow row, DateTime today) {
    final cashier = _cashierFor(row.name);
    final resignedAt = cashier?.resignedAt;
    final inactiveNote = cashier == null
        ? null
        : isCashierResigned(cashier)
            ? 'resign ${formatShortDate(resignedAt!)}'
            : !cashier.active
                ? 'nonaktif'
                : null;
    return Card(
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RiwayatPage(
              role: AppRole.owner,
              outletId: row.outletId,
              cashierName: row.name,
              day: today,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  Text(
                    formatRupiah(row.omzet),
                    style: const TextStyle(
                      color: SukaTeaColors.emerald,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${row.sales} jualan · ${row.cups} cup'
                '${inactiveNote == null ? '' : ' · $inactiveNote'}',
                style: const TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    'Void ${row.voidCount}',
                    style: TextStyle(
                      color: row.voidCount > 0
                          ? SukaTeaColors.danger
                          : SukaTeaColors.muted,
                      fontWeight: row.voidCount > 0
                          ? FontWeight.w800
                          : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'Diskon ${row.discountCount}',
                    style:
                        const TextStyle(color: SukaTeaColors.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
