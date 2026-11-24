import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/c10_models.dart';
import '../../data/outlet_service.dart';
import '../../data/package_service.dart';
import '../../data/sync_service.dart';
import 'gudang_common.dart';
import 'package_edit_page.dart';
import 'send_stock_page.dart';

/// Paket Kiriman (Batch C10 WS2, FigCraft v32 frame 19).
/// Owner-only. Daftar paket aktif: nama, chip Default Gerai /
/// "Tanpa default", ringkasan bahan + "+N bahan lagi", tombol
/// Kirim / Ubah / Salin / Hapus. "+ Buat Paket" 56px.
/// Hapus = konfirmasi + is_deleted (paket default gerai TIDAK
/// bisa dihapus sebelum default-nya dipindah).
class PackageListPage extends StatefulWidget {
  const PackageListPage({super.key});

  @override
  State<PackageListPage> createState() => _PackageListPageState();
}

class _PackageListPageState extends State<PackageListPage> {
  String _defaultLabel(String packageId) {
    final names = <String>[];
    for (final o in OutletService.instance.outlets) {
      if (PackageService.instance.defaultPackageIdFor(o.id) == packageId) {
        names.add(o.name);
      }
    }
    if (names.isEmpty) return 'Tanpa default';
    return 'Default: ${names.join(', ')}';
  }

  Future<void> _confirmDelete(StockPackage pkg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus paket "${pkg.name}"?'),
        content: const Text(
          'Paket tidak bisa dipakai lagi untuk kirim. Riwayat '
          'kiriman lama tetap tersimpan.',
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
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final deleted = await PackageService.instance.deletePackage(pkg.id);
    if (!mounted) return;
    if (!deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Paket "${pkg.name}" masih jadi default gerai — '
            'pindahkan dulu default-nya.',
          ),
        ),
      );
      return;
    }
    unawaited(SyncService.instance.syncNow());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Paket "${pkg.name}" dihapus.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Paket Kiriman')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          PackageService.instance,
          OutletService.instance,
        ]),
        builder: (context, _) {
          final packages = PackageService.instance.activePackages;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: GudangPrimaryButton(
                  label: 'Buat Paket',
                  icon: Icons.add,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PackageEditPage(),
                    ),
                  ),
                ),
              ),
              if (packages.isEmpty)
                const Expanded(
                  child: GudangEmptyState(
                    message:
                        'Belum ada paket. Buat paket dulu — paket adalah '
                        'jatah stok yang dikirim ke gerai tiap hari.',
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: packages.length,
                    itemBuilder: (context, i) {
                      final pkg = packages[i];
                      final shown = pkg.items.take(3).toList();
                      final rest = pkg.items.length - shown.length;
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      pkg.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 17,
                                      ),
                                    ),
                                  ),
                                  Chip(
                                    label: Text(_defaultLabel(pkg.id)),
                                    backgroundColor:
                                        _defaultLabel(pkg.id) == 'Tanpa default'
                                            ? SukaTeaColors.pillAmberBg
                                            : SukaTeaColors.emeraldSoft,
                                    labelStyle: TextStyle(
                                      color: _defaultLabel(pkg.id) ==
                                              'Tanpa default'
                                          ? SukaTeaColors.amber
                                          : SukaTeaColors.emeraldDark,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    side: BorderSide.none,
                                  ),
                                ],
                              ),
                              if (pkg.note.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  pkg.note,
                                  style: const TextStyle(
                                    color: SukaTeaColors.muted,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              for (final it in shown)
                                Text(
                                  '• ${it.stockName}: '
                                  '${qtyText(it.qty)} ${it.unit}',
                                  style: const TextStyle(
                                    color: SukaTeaColors.muted,
                                  ),
                                ),
                              if (rest > 0)
                                Text(
                                  '+$rest bahan lagi',
                                  style: const TextStyle(
                                    color: SukaTeaColors.muted,
                                  ),
                                ),
                              if (pkg.items.isEmpty)
                                const Text(
                                  'Paket masih kosong — isi jumlahnya dulu.',
                                  style: TextStyle(
                                    color: SukaTeaColors.danger,
                                  ),
                                ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () =>
                                          Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => SendStockPage(
                                            packageId: pkg.id,
                                          ),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.local_shipping,
                                        size: 18,
                                      ),
                                      label: const Text('Kirim'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () =>
                                        Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => PackageEditPage(
                                          packageId: pkg.id,
                                        ),
                                      ),
                                    ),
                                    child: const Text('Ubah'),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () async {
                                      final messenger =
                                          ScaffoldMessenger.of(context);
                                      final copy =
                                          await PackageService.instance
                                              .copyPackage(pkg.id);
                                      if (!mounted) return;
                                      unawaited(
                                        SyncService.instance.syncNow(),
                                      );
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            copy == null
                                                ? 'Gagal menyalin paket.'
                                                : 'Paket "${copy.name}" dibuat.',
                                          ),
                                        ),
                                      );
                                    },
                                    child: const Text('Salin'),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    onPressed: () => _confirmDelete(pkg),
                                    tooltip: 'Hapus paket',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: SukaTeaColors.danger,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
