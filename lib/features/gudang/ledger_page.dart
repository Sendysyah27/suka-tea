import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/brew_service.dart';
import '../../data/c10_models.dart';
import '../../data/outlet_service.dart';
import '../../data/package_service.dart';
import '../../data/seed_menu.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import 'gudang_common.dart';

/// Riwayat Keluar-Masuk Barang (Batch C10 WS8, FigCraft v32
/// frame 24). Owner-only. Filter gerai + tanggal + jenis.
/// Baris ledger: tanggal+jam, jenis (MASUK/KELUAR/TERBUANG/
//// OPNAME/MASAK/KOREKSI), bahan, jumlah + satuan, referensi, oleh.
/// Ringkasan per bahan (masuk, keluar, terbuang, selisih opname,
/// sisa) HARUS sama dengan stok sistem — mismatch -> banner merah
/// "Selisih pembukuan — laporkan ke Jhon" + selisihnya (tidak
/// pernah disembunyikan).
///
/// CATATAN JUJUR: ringkasan hanya menutup bila SEMUA riwayat ada
/// di HP ini. HP baru hanya punya 30 hari pull + data lokal —
/// mutasi lama dari HP lain (termasuk yang hilang karena bug 23505
/// sebelum C9) tidak ada di sini, jadi gap bisa muncul.
class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key, this.outletId});

  final String? outletId;

  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  String? _outletId;
  DateTime _day = DateTime.now();
  LedgerKind? _kindFilter;

  @override
  void initState() {
    super.initState();
    _outletId = widget.outletId ?? OutletService.instance.currentOutletId;
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: today.subtract(const Duration(days: 30)),
      lastDate: today,
      helpText: 'Tanggal',
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _changeOutlet(String? id) async {
    if (id == null) return;
    setState(() => _outletId = id);
    // Tarik data gerai itu (penjualan + mutasi + stok) supaya
    // ledger-nya dari server, bukan dari gerai sebelumnya.
    unawaited(SyncService.instance.refreshSales(outletId: id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Riwayat Keluar-Masuk')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          PackageService.instance,
          BrewService.instance,
          StockService.instance,
          SyncService.instance,
          OutletService.instance,
        ]),
        builder: (context, _) {
          final outletId = _outletId ??
              OutletService.instance.currentOutletId;
          final systemStock =
              StockService.instance.stockByNameFor(outletId);
          final movements = SyncService.instance.lastMovements
              .where((m) => m.outletId == outletId)
              .map((m) => (
                    clientUuid: m.clientUuid,
                    name: m.name,
                    qtyDelta: m.qtyDelta,
                    reason: m.reason,
                    createdAt: m.createdAt,
                  ))
              .toList();
          final result = buildLedger(
            outletId: outletId,
            sends: PackageService.instance.sends,
            movements: movements,
            opnames: PackageService.instance.opnames,
            brews: BrewService.instance.brews,
            openingQty: {for (final s in seedStock()) s.name: s.qty},
            systemStock: systemStock,
          );
          final dayEntries = result.entries
              .where((e) =>
                  e.at.year == _day.year &&
                  e.at.month == _day.month &&
                  e.at.day == _day.day)
              .toList();
          final filtered = _kindFilter == null
              ? dayEntries
              : dayEntries.where((e) => e.kind == _kindFilter).toList();
          final mismatches =
              result.summary.where((s) => !s.matches).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: outletId,
                            decoration: const InputDecoration(
                              labelText: 'Gerai',
                            ),
                            items: [
                              for (final o in OutletService.instance.outlets)
                                DropdownMenuItem(
                                  value: o.id,
                                  child: Text(o.name),
                                ),
                            ],
                            onChanged: _changeOutlet,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkWell(
                            onTap: _pickDay,
                            borderRadius: BorderRadius.circular(12),
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Tanggal',
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${_day.day}/${_day.month}/${_day.year}',
                                    ),
                                  ),
                                  const Icon(
                                    Icons.calendar_today,
                                    size: 18,
                                    color: SukaTeaColors.muted,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final kind in [
                            null,
                            ...LedgerKind.values,
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(
                                  kind == null ? 'Semua' : kind.label,
                                ),
                                selected: _kindFilter == kind,
                                onSelected: (_) =>
                                    setState(() => _kindFilter = kind),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (mismatches.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: SukaTeaColors.deleteBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Selisih pembukuan — laporkan ke Jhon',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: SukaTeaColors.danger,
                          ),
                        ),
                        for (final s in mismatches)
                          Text(
                            '${s.stockName}: sistem ${qtyText(s.systemQty)} ${s.unit} '
                            'vs pembukuan ${qtyText(s.expectedQty)} ${s.unit} '
                            '(selisih ${s.gap > 0 ? '+' : ''}${qtyText(s.gap)})',
                            style: const TextStyle(
                              color: SukaTeaColors.danger,
                            ),
                          ),
                        const Text(
                          'Kemungkinan: HP ini belum punya riwayat lama '
                          '(baru 30 hari) atau mutasi lama hilang (bug '
                          '23505 sebelum C9).',
                          style: TextStyle(
                            color: SukaTeaColors.danger,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    const GudangSectionTitle('Ringkasan per bahan'),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            for (final s in result.summary)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        s.stockName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      'M ${qtyText(s.masuk)} • K ${qtyText(s.keluar)}'
                                      '${s.terbuang > 0 ? ' • T ${qtyText(s.terbuang)}' : ''}'
                                      '${s.opname != 0 ? ' • O ${s.opname > 0 ? '+' : ''}${qtyText(s.opname)}' : ''}'
                                      ' • Sisa ${qtyText(s.systemQty)} ${s.unit}',
                                      style: TextStyle(
                                        color: s.matches
                                            ? SukaTeaColors.muted
                                            : SukaTeaColors.danger,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const GudangSectionTitle('Baris keluar-masuk'),
                    const SizedBox(height: 8),
                    if (filtered.isEmpty)
                      const GudangEmptyState(
                        message:
                            'Tidak ada pergerakan barang di tanggal ini '
                            '(atau filter jenis tidak cocok).',
                      )
                    else
                      for (final e in filtered)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Chip(
                                      label: Text(e.kind.label),
                                      backgroundColor:
                                          e.kind == LedgerKind.keluar
                                              ? SukaTeaColors.deleteBg
                                              : e.kind == LedgerKind.masuk
                                                  ? SukaTeaColors.emeraldSoft
                                                  : SukaTeaColors.pillAmberBg,
                                      labelStyle: TextStyle(
                                        color: e.kind == LedgerKind.keluar
                                            ? SukaTeaColors.danger
                                            : e.kind == LedgerKind.masuk
                                                ? SukaTeaColors.emeraldDark
                                                : SukaTeaColors.amber,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      side: BorderSide.none,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${e.stockName}: '
                                        '${e.qty > 0 ? '+' : ''}'
                                        '${qtyText(e.qty)} ${e.unit}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${e.at.day}/${e.at.month}/${e.at.year} '
                                  '${e.at.hour.toString().padLeft(2, '0')}:'
                                  '${e.at.minute.toString().padLeft(2, '0')}'
                                  ' • ${e.reference}'
                                  '${e.by.isNotEmpty ? ' • ${e.by}' : ''}',
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
            ],
          );
        },
      ),
    );
  }
}
