import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/brew_service.dart';
import '../../data/c10_models.dart';
import '../../data/outlet_service.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import 'gudang_common.dart';

/// Masak Teh (Batch C10 WS4, FigCraft v32 frame 22).
/// Owner + Kasir. Kartu saldo (Teh Kering + Teh Masak gerai),
/// 2 field angka (kg dipakai → liter dihasilkan — TANPA rasio
/// asumsi, keduanya dari masakan nyata), Simpan 56px, riwayat
/// masak (termasuk baris terbuang / kedaluwarsa), kartu info sisa
/// Teh Masak yang terbuang malam ini (hanya bertahan sehari).
class BrewPage extends StatefulWidget {
  const BrewPage({super.key, this.outletId});

  /// Gerai yang dimasak (null = gerai aktif).
  final String? outletId;

  @override
  State<BrewPage> createState() => _BrewPageState();
}

class _BrewPageState extends State<BrewPage> {
  String? _outletId;
  final _kgCtrl = TextEditingController();
  final _literCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _outletId = widget.outletId ?? OutletService.instance.currentOutletId;
  }

  @override
  void dispose() {
    _kgCtrl.dispose();
    _literCtrl.dispose();
    super.dispose();
  }

  Future<void> _brew() async {
    if (_saving) return;
    final outletId = _outletId;
    if (outletId == null) return;
    final kg = parseQty(_kgCtrl.text);
    final liters = parseQty(_literCtrl.text);
    if (kg == null || kg <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Teh Kering dipakai harus angka > 0.')),
      );
      return;
    }
    if (liters == null || liters <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Teh Masak dihasilkan harus angka > 0.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    final record = await BrewService.instance.brew(
      outletId: outletId,
      kgUsed: kg,
      litersMade: liters,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (record == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Teh Kering di gerai kurang — kirim dulu dari gudang.',
          ),
        ),
      );
      return;
    }
    _kgCtrl.clear();
    _literCtrl.clear();
    unawaited(SyncService.instance.syncNow());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Masak: ${qtyText(kg)} kg Teh Kering → '
          '${qtyText(liters)} L Teh Masak.'
          '${record.expiredLiters > 0 ? ' (Sisa kemarin ${qtyText(record.expiredLiters)} L terbuang.)' : ''}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Masak Teh')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          BrewService.instance,
          StockService.instance,
          OutletService.instance,
        ]),
        builder: (context, _) {
          final outletId = _outletId ??
              OutletService.instance.currentOutletId;
          final stock = StockService.instance.stockByNameFor(outletId);
          final kering = stock[tehKeringName]?.qty ?? 0;
          final masak = stock[tehMasakName]?.qty ?? 0;
          final brews = BrewService.instance.brewsFor(outletId);
          final state = BrewService.instance.stateFor(outletId);
          final hasFresh = BrewService.instance.hasFreshTehMasak(outletId);
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
                        onChanged: (v) =>
                            setState(() => _outletId = v),
                      ),
                      const SizedBox(height: 16),
                      GudangRow(
                        label: 'Teh Kering (gerai)',
                        value: '${qtyText(kering)} kg',
                      ),
                      GudangRow(
                        label: 'Teh Masak (hari ini)',
                        value: '${qtyText(masak)} L',
                        valueColor: masak <= 0
                            ? SukaTeaColors.danger
                            : null,
                      ),
                      if (state != null && hasFresh) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: SukaTeaColors.pillAmberBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Sisa Teh Masak ${qtyText(masak)} L akan '
                            'terbuang malam ini — teh yang sudah '
                            'dimasak hanya bertahan sehari.',
                            style: const TextStyle(
                              color: SukaTeaColors.amber,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        controller: _kgCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Teh Kering dipakai (kg)',
                          hintText: 'mis. 0,5',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _literCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Teh Masak dihasilkan (liter)',
                          hintText: 'mis. 12',
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Isi sesuai masakan nyata — app tidak mengasumsikan rasio.',
                        style: TextStyle(
                          color: SukaTeaColors.muted,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 16),
                      GudangPrimaryButton(
                        label: _saving ? 'Menyimpan…' : 'Simpan Masakan',
                        onPressed: _saving ? null : _brew,
                        icon: Icons.local_cafe,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const GudangSectionTitle('Riwayat masak'),
              const SizedBox(height: 8),
              if (brews.isEmpty)
                const GudangEmptyState(
                  message:
                      'Belum pernah masak di gerai ini. Masak dulu '
                      'sebelum jualan — menu teh butuh Teh Masak.',
                )
              else
                for (final b in brews.take(20))
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${qtyText(b.kgUsed)} kg Teh Kering → '
                            '${qtyText(b.litersMade)} L Teh Masak',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${b.brewedAt.day}/${b.brewedAt.month}/${b.brewedAt.year} '
                            '${b.brewedAt.hour.toString().padLeft(2, '0')}:'
                            '${b.brewedAt.minute.toString().padLeft(2, '0')}'
                            ' • ${b.brewedBy}',
                            style: const TextStyle(
                              color: SukaTeaColors.muted,
                            ),
                          ),
                          if (b.expiredLiters > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Terbuang: ${qtyText(b.expiredLiters)} L '
                              'sisa kemarin (kedaluwarsa).',
                              style: const TextStyle(
                                color: SukaTeaColors.danger,
                              ),
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
