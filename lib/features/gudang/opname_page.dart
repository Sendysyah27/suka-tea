import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/c10_models.dart';
import '../../data/outlet_service.dart';
import '../../data/package_service.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import 'gudang_common.dart';

/// Opname + selisih (Batch C10 WS6, FigCraft v32 frame 23).
/// Owner-only. Pilih gerai → tanggal (default hari ini) → per
/// bahan: Sistem (read-only) + Fisik (input; KOSONG = belum
/// dihitung, BUKAN 0). Simpan Opname 56px = satu sesi opname
/// (opname kedua di hari yang sama = entri BARU, tidak menimpa).
/// Selisih = fisik − sistem; ringkasan (dihitung / berselisih /
/// selisih Rp perkiraan dari harga bahan). "Sesuaikan stok"
/// EKSPLISIT per baris — tidak pernah otomatis; baris yang sudah
/// disesuaikan ditandai "Sudah disesuaikan {jam}".
class OpnamePage extends StatefulWidget {
  const OpnamePage({super.key, this.outletId});

  final String? outletId;

  @override
  State<OpnamePage> createState() => _OpnamePageState();
}

class _OpnamePageState extends State<OpnamePage> {
  String? _outletId;
  DateTime _date = DateTime.now();
  final Map<String, TextEditingController> _physicalCtrls = {};
  List<StockOpname> _lastSaved = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _outletId = widget.outletId ?? OutletService.instance.currentOutletId;
  }

  @override
  void dispose() {
    for (final c in _physicalCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrlFor(String name) =>
      _physicalCtrls.putIfAbsent(name, () => TextEditingController());

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today.subtract(const Duration(days: 30)),
      lastDate: today,
      helpText: 'Tanggal opname',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (_saving) return;
    final outletId = _outletId;
    if (outletId == null) return;
    final levels = StockService.instance.levelsFor(outletId);
    final rows = <StockOpname>[];
    for (final item in levels) {
      final raw = _physicalCtrls[item.name]?.text.trim() ?? '';
      if (raw.isEmpty) continue; // Belum dihitung — BUKAN 0.
      final physical = parseQty(raw);
      if (physical == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Jumlah fisik ${item.name} tidak valid — isi angka ≥ 0.',
            ),
          ),
        );
        return;
      }
      rows.add(StockOpname(
        id: '',
        outletId: outletId,
        stockName: item.name,
        systemQty: item.qty,
        physicalQty: physical,
        countedAt: _date,
        countedBy: 'Owner',
        updatedAt: DateTime.now().toUtc(),
      ));
    }
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Isi dulu jumlah fisik minimal 1 bahan — baris kosong '
            'berarti belum dihitung.',
          ),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    final saved = await PackageService.instance.saveOpname(
      outletId: outletId,
      rows: rows,
      countedBy: 'Owner',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _lastSaved = saved;
    });
    for (final c in _physicalCtrls.values) {
      c.clear();
    }
    unawaited(SyncService.instance.syncNow());
    final differing = saved.where((o) => o.difference != 0).length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Opname tersimpan: ${saved.length} bahan dihitung, '
          '$differing berselisih.',
        ),
      ),
    );
  }

  Future<void> _adjust(StockOpname row) async {
    final ok = await PackageService.instance.adjustOpname(row.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Baris ini sudah disesuaikan / selisih 0.'),
        ),
      );
      return;
    }
    unawaited(SyncService.instance.syncNow());
    setState(() {
      _lastSaved = _lastSaved
          .map((o) => o.id == row.id ? o.copyWith(adjusted: true) : o)
          .toList();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Stok ${row.stockName} disesuaikan '
          '(${qtyText(row.systemQty)} → ${qtyText(row.physicalQty)}).',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Opname Stok')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          PackageService.instance,
          StockService.instance,
          OutletService.instance,
        ]),
        builder: (context, _) {
          final outletId = _outletId ??
              OutletService.instance.currentOutletId;
          final levels = StockService.instance.levelsFor(outletId);
          final history = PackageService.instance.opnamesFor(outletId);
          final differingSaved =
              _lastSaved.where((o) => o.difference != 0).toList();
          final totalRp = _lastSaved.fold<double>(
            0,
            (sum, o) {
              final cost = StockService.instance
                      .stockByNameFor(outletId)[o.stockName]
                      ?.costPerUnit ??
                  0;
              return sum + o.difference * (cost < 0 ? 0 : cost);
            },
          );
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<String>(
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
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _outletId = v;
                            _lastSaved = [];
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: _pickDate,
                        borderRadius: BorderRadius.circular(12),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Tanggal opname',
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_date.day}/${_date.month}/${_date.year}',
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
                      const SizedBox(height: 16),
                      const Text(
                        'Hitung fisik tiap bahan, lalu isi kolom Fisik. '
                        'Baris yang dikosongkan berarti belum dihitung '
                        '(bukan 0).',
                        style: TextStyle(color: SukaTeaColors.muted),
                      ),
                      const SizedBox(height: 12),
                      for (final item in levels)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'Sistem: ${qtyText(item.qty)} ${item.unit}',
                                      style: const TextStyle(
                                        color: SukaTeaColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 3,
                                child: TextField(
                                  controller: _ctrlFor(item.name),
                                  keyboardType: const TextInputType
                                      .numberWithOptions(decimal: true),
                                  decoration: InputDecoration(
                                    labelText: 'Fisik (${item.unit})',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      GudangPrimaryButton(
                        label: _saving ? 'Menyimpan…' : 'Simpan Opname',
                        onPressed: _saving ? null : _save,
                        icon: Icons.fact_check,
                      ),
                    ],
                  ),
                ),
              ),
              if (_lastSaved.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const GudangSectionTitle('Hasil opname ini'),
                        const SizedBox(height: 8),
                        GudangRow(
                          label: 'Bahan dihitung',
                          value: '${_lastSaved.length}',
                        ),
                        GudangRow(
                          label: 'Bahan berselisih',
                          value: '${differingSaved.length}',
                          valueColor: differingSaved.isNotEmpty
                              ? SukaTeaColors.danger
                              : null,
                        ),
                        GudangRow(
                          label: 'Selisih (perkiraan)',
                          value: formatRupiah(totalRp.round()),
                          valueColor: totalRp < 0
                              ? SukaTeaColors.danger
                              : null,
                        ),
                        const SizedBox(height: 12),
                        for (final o in _lastSaved)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        o.stockName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        'Sistem ${qtyText(o.systemQty)} → '
                                        'Fisik ${qtyText(o.physicalQty)} '
                                        '(selisih ${o.difference > 0 ? '+' : ''}'
                                        '${qtyText(o.difference)})',
                                        style: TextStyle(
                                          color: o.difference == 0
                                              ? SukaTeaColors.muted
                                              : SukaTeaColors.danger,
                                          fontSize: 12,
                                        ),
                                      ),
                                      if (o.adjusted)
                                        const Text(
                                          'Sudah disesuaikan',
                                          style: TextStyle(
                                            color: SukaTeaColors.emeraldDark,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (o.difference != 0 && !o.adjusted)
                                  OutlinedButton(
                                    onPressed: () => _adjust(o),
                                    child: const Text('Sesuaikan stok'),
                                  ),
                              ],
                            ),
                          ),
                        const Text(
                          '"Sesuaikan stok" mengubah stok sistem '
                          'sebesar selisih — hanya bila ditekan.',
                          style: TextStyle(
                            color: SukaTeaColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const GudangSectionTitle('Riwayat opname'),
              const SizedBox(height: 8),
              if (history.isEmpty)
                const GudangEmptyState(
                  message: 'Belum ada opname di gerai ini.',
                )
              else
                for (final o in history.take(10))
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  o.stockName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Chip(
                                label: Text(
                                  o.adjusted
                                      ? 'Sudah disesuaikan'
                                      : 'Belum disesuaikan',
                                ),
                                backgroundColor: o.adjusted
                                    ? SukaTeaColors.emeraldSoft
                                    : SukaTeaColors.pillAmberBg,
                                labelStyle: TextStyle(
                                  color: o.adjusted
                                      ? SukaTeaColors.emeraldDark
                                      : SukaTeaColors.amber,
                                  fontWeight: FontWeight.w600,
                                ),
                                side: BorderSide.none,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${o.countedAt.day}/${o.countedAt.month}/${o.countedAt.year} '
                            '${o.countedAt.hour.toString().padLeft(2, '0')}:'
                            '${o.countedAt.minute.toString().padLeft(2, '0')}'
                            ' • Sistem ${qtyText(o.systemQty)} → Fisik '
                            '${qtyText(o.physicalQty)} '
                            '(selisih ${o.difference > 0 ? '+' : ''}'
                            '${qtyText(o.difference)}) • ${o.countedBy}',
                            style: const TextStyle(
                              color: SukaTeaColors.muted,
                            ),
                          ),
                          if (o.difference != 0 && !o.adjusted) ...[
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: () => _adjust(o),
                              child: const Text('Sesuaikan stok'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}
