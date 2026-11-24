import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/c10_models.dart';
import '../../data/outlet_service.dart';
import '../../data/package_service.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import 'gudang_common.dart';

/// Buat / Ubah Paket (Batch C10 WS2, FigCraft v32 frame 20).
/// Nama (wajib, unik) + Catatan + daftar item (bahan + jumlah +
/// satuan baku terkunci) + "[+ Tambah bahan]" + Default gerai
/// (chip per gerai, boleh kosong) + Simpan 56px.
/// Bahan yang sama 2x dalam satu paket DITOLAK (pesan jelas).
/// Jumlah 0 = item tidak ikut terkirim (template bawaan dibuat
/// dengan jumlah 0 — Owner mengisinya sekali di sini).
class PackageEditPage extends StatefulWidget {
  const PackageEditPage({super.key, this.packageId});

  /// null = buat baru; terisi = ubah paket ini.
  final String? packageId;

  @override
  State<PackageEditPage> createState() => _PackageEditPageState();
}

class _PackageEditPageState extends State<PackageEditPage> {
  final _nameCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final List<_ItemRow> _rows = [];
  final Set<String> _defaultOutlets = {};
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  void _loadExisting() {
    final id = widget.packageId;
    if (id == null) {
      _loaded = true;
      return;
    }
    final pkg = PackageService.instance.packageById(id);
    if (pkg == null) {
      _loaded = true;
      return;
    }
    _nameCtrl.text = pkg.name;
    _noteCtrl.text = pkg.note;
    for (final it in pkg.items) {
      _rows.add(_ItemRow(
        name: it.stockName,
        qtyCtrl: TextEditingController(text: qtyText(it.qty)),
        unit: it.unit,
      ));
    }
    for (final o in OutletService.instance.outlets) {
      if (PackageService.instance.defaultPackageIdFor(o.id) == id) {
        _defaultOutlets.add(o.id);
      }
    }
    _loaded = true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _noteCtrl.dispose();
    for (final r in _rows) {
      r.qtyCtrl.dispose();
    }
    super.dispose();
  }

  /// Katalog bahan kanonik (Batch C10.2 W1) — BUKAN level stok gudang.
  /// Gudang tidak pernah di-seed (selalu kosong di POCO), jadi
  /// membaca level gudang membuat dropdown kosong + semua baris
  /// template tampil label "Bahan" dengan jumlah 0.
  List<String> get _allNames =>
      StockService.instance.allKnownStockNames.keys.toList()..sort();

  String? _unitOf(String name) =>
      StockService.instance.allKnownStockNames[name];

  void _addRow() {
    final used = _rows.map((r) => r.name).toSet();
    final available =
        _allNames.where((n) => !used.contains(n)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Semua bahan sudah ada di paket ini.'),
        ),
      );
      return;
    }
    setState(() {
      _rows.add(_ItemRow(
        name: available.first,
        qtyCtrl: TextEditingController(),
        unit: _unitOf(available.first) ?? 'pcs',
      ));
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama paket tidak boleh kosong.')),
      );
      return;
    }
    final seen = <String>{};
    final items = <SendItem>[];
    for (final row in _rows) {
      if (row.name == null) continue;
      if (!seen.add(row.name!.toLowerCase())) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Bahan ${row.name} ada 2x di paket ini — hapus salah satu.',
            ),
          ),
        );
        return;
      }
      final qty = parseQty(row.qtyCtrl.text) ?? 0;
      // Jumlah 0 = item tidak ikut terkirim (template bawaan —
      // Owner mengisinya nanti). Item 0 TETAP disimpan supaya
      // template tidak kehilangan bahannya sesudah disimpan.
      items.add(SendItem(
        stockName: row.name!,
        qty: qty,
        unit: row.unit,
      ));
    }
    setState(() => _saving = true);
    StockPackage? saved;
    if (widget.packageId == null) {
      saved = await PackageService.instance.createPackage(
        name: name,
        note: _noteCtrl.text.trim(),
        items: items,
      );
      if (saved == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Nama paket sudah dipakai / ada bahan dobel. '
              'Coba nama lain.',
            ),
          ),
        );
        setState(() => _saving = false);
        return;
      }
    } else {
      final ok = await PackageService.instance.updatePackage(
        widget.packageId!,
        name: name,
        note: _noteCtrl.text.trim(),
        items: items,
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Nama paket sudah dipakai paket lain / ada bahan dobel.',
            ),
          ),
        );
        setState(() => _saving = false);
        return;
      }
      saved = PackageService.instance.packageById(widget.packageId!);
    }
    // Default gerai: satu paket default per gerai — gerai yang
    // dicentang di sini memakai paket ini (gerai lain yang tadinya
    // memakai paket ini tetap, kecuali dicentang paket lain).
    final targetId = saved?.id ?? widget.packageId;
    if (targetId != null) {
      for (final outletId in _defaultOutlets) {
        await PackageService.instance.setDefaultPackage(
          outletId,
          targetId,
        );
      }
      // Gerai yang sebelumnya default paket ini tapi tidak dicentang
      // lagi = hapus default-nya.
      for (final o in OutletService.instance.outlets) {
        if (PackageService.instance.defaultPackageIdFor(o.id) ==
                targetId &&
            !_defaultOutlets.contains(o.id)) {
          await PackageService.instance.setDefaultPackage(o.id, null);
        }
      }
    }
    unawaited(SyncService.instance.syncNow());
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Paket "$name" disimpan.')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: ScreenTitle(
          widget.packageId == null ? 'Buat Paket' : 'Ubah Paket',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nama paket (wajib)',
                      hintText: 'mis. Paket Standar Harian',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _noteCtrl,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Catatan (opsional)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const GudangSectionTitle('Isi paket'),
                  const SizedBox(height: 8),
                  if (_rows.isEmpty)
                    const Text(
                      'Paket masih kosong — tambah bahan di bawah. '
                      'Jumlah 0 berarti bahan tidak ikut terkirim.',
                      style: TextStyle(color: SukaTeaColors.muted),
                    ),
                  for (var i = 0; i < _rows.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: DropdownButtonFormField<String>(
                              initialValue: _rows[i].name,
                              decoration: const InputDecoration(
                                labelText: 'Bahan',
                              ),
                              items: [
                                for (final n in _allNames)
                                  DropdownMenuItem(
                                    value: n,
                                    child: Text(n),
                                  ),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() {
                                  _rows[i].name = v;
                                  _rows[i].unit = _unitOf(v) ?? 'pcs';
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _rows[i].qtyCtrl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: InputDecoration(
                                labelText: 'Jumlah (${_rows[i].unit})',
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () =>
                                setState(() => _rows.removeAt(i)),
                            tooltip: 'Hapus bahan',
                            icon: const Icon(
                              Icons.delete_outline,
                              color: SukaTeaColors.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: _addRow,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Tambah bahan'),
                  ),
                  const SizedBox(height: 16),
                  const GudangSectionTitle('Default gerai'),
                  const SizedBox(height: 4),
                  const Text(
                    'Gerai yang memakai paket ini sebagai paket '
                    'default (terisi otomatis saat Kirim).',
                    style: TextStyle(
                      color: SukaTeaColors.muted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final o in OutletService.instance.outlets)
                        ChoiceChip(
                          label: Text(o.name),
                          selected: _defaultOutlets.contains(o.id),
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _defaultOutlets.add(o.id);
                              } else {
                                _defaultOutlets.remove(o.id);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GudangPrimaryButton(
                    label: _saving ? 'Menyimpan…' : 'Simpan',
                    onPressed: _saving ? null : _save,
                    icon: Icons.save,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow {
  _ItemRow({required this.name, required this.qtyCtrl, required this.unit});

  String? name;
  TextEditingController qtyCtrl;
  String unit;
}
