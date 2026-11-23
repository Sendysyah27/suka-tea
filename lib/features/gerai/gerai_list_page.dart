import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/outlet_service.dart';
import '../../data/sale_history.dart';
import 'gerai_edit_page.dart';
import 'gerai_monitor_page.dart';

/// Daftar Gerai (Batch C4, FigCraft v29 frame 14): semua gerai + total
/// hari ini per gerai + total semua gerai + tambah gerai.
///
/// DATA JUJUR: angka "Hari ini" dihitung dari penjualan LOKAL di HP
/// ini (SaleHistoryService, per outletId). Gerai yang tidak pernah
/// dibuka di HP ini angkanya Rp0 — BUKAN karena gerai itu sepi, tapi
/// karena penjualan gerai lain belum tersinkron ke HP ini (sinkronisasi
/// Supabase belum ada — lihat C4-GERAI-PLAN.md). Catatan itu ditulis
/// di bawah daftar, supaya Owner tidak salah baca.
class GeraiListPage extends StatelessWidget {
  const GeraiListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Gerai')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          OutletService.instance,
          SaleHistoryService.instance,
        ]),
        builder: (context, _) {
          final outlets = OutletService.instance.outlets;
          final today = DateTime.now();
          var totalAll = 0;
          final totals = <String, (int, int)>{};
          for (final outlet in outlets) {
            final sales = SaleHistoryService.instance.activeSalesOn(
              today,
              outletId: outlet.id,
            );
            final omzet = sales.fold<int>(0, (sum, s) => sum + s.total);
            totals[outlet.id] = (omzet, sales.length);
            totalAll += omzet;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (var i = 0; i < outlets.length; i++)
                _geraiCard(context, outlets[i], i + 1, totals[outlets[i].id]!),
              const SizedBox(height: 4),
              FilledButton(
                onPressed: () => _addGerai(context),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 56),
                ),
                child: const Text(
                  '+ Tambah gerai',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Total hari ini semua gerai: ${formatRupiah(totalAll)}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Angka di atas dihitung dari penjualan di HP ini. Gerai '
                'yang belum pernah dibuka di HP ini tampil Rp0 sampai '
                'sinkronisasi Supabase aktif.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: SukaTeaColors.muted,
                  fontSize: 12,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addGerai(BuildContext context) async {
    final count = OutletService.instance.outlets.length + 1;
    final outlet = await OutletService.instance.addOutlet(
      name: 'Gerai $count',
    );
    // addOutlet selalu mengembalikan Outlet (tidak pernah null).
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GeraiEditPage(outlet: outlet)),
    );
  }

  Widget _geraiCard(
    BuildContext context,
    Outlet outlet,
    int number,
    (int, int) today,
  ) {
    final (omzet, txnCount) = today;
    final isCurrent =
        outlet.id == OutletService.instance.currentOutletId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GeraiMonitorPage(outlet: outlet),
          ),
        ),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isCurrent ? SukaTeaColors.tint : SukaTeaColors.card,
            border: Border.all(
              color: isCurrent
                  ? SukaTeaColors.emerald
                  : SukaTeaColors.border,
              width: isCurrent ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: SukaTeaColors.emerald,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      outlet.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      outlet.address.isEmpty
                          ? 'Alamat gerai (isi dari Pengaturan)'
                          : outlet.address,
                      style: const TextStyle(
                        color: SukaTeaColors.muted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Hari ini: ${formatRupiah(omzet)} • $txnCount transaksi',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: outlet.isOpen
                              ? SukaTeaColors.emerald
                              : SukaTeaColors.muted,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        outlet.isOpen ? 'Buka' : 'Tutup',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Ubah gerai',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GeraiEditPage(outlet: outlet),
                      ),
                    ),
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
