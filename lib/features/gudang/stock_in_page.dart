import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/c10_models.dart';
import '../../data/local/outbox_service.dart';
import '../../data/package_service.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import 'gudang_common.dart';

/// Stok Masuk gudang (Batch C10 WS1, FigCraft v32 frame 18).
/// Owner-only. Form: Bahan (+ Bahan baru) / Jumlah (satuan baku
/// terkunci) / Harga beli total (opsional) / Supplier (opsional) /
/// Tanggal (default hari ini, ≤ hari ini, maks 30 hari mundur) /
/// Catatan (opsional) + Simpan 56px. Simpan = gudang += jumlah
/// (atomik lokal) + event 'stock_in' ke server + syncNow.
///
/// Riwayat masuk (20 terbaru + "Lihat semua") dengan status
/// sinkron: ✓ Terkirim / Menunggu sinkron. TIDAK ADA edit/hapus
/// riwayat (audit trail) — salah catat diperbaiki lewat Opname.
class StockInPage extends StatefulWidget {
  const StockInPage({super.key});

  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  String? _selectedName;
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _supplierCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  bool _showAll = false;
  bool _saving = false;
  Set<String> _pendingIds = {};

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _supplierCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPending() async {
    try {
      final pending = await OutboxService.instance.pendingEntries();
      final ids = <String>{};
      for (final e in pending) {
        if (e.kind != 'stock_in') continue;
        // id StockInRecord == client_uuid event (bukan id outbox).
        try {
          final raw = jsonDecode(e.payload);
          if (raw is Map && raw['client_uuid'] is String) {
            ids.add(raw['client_uuid'] as String);
          }
        } catch (_) {}
      }
      if (mounted) setState(() => _pendingIds = ids);
    } catch (_) {}
  }

  List<String> get _gudangNames {
    final names = StockService.instance
        .stockByNameFor(gudangOutletId)
        .keys
        .toList()
      ..sort();
    return names;
  }

  String? get _selectedUnit {
    if (_selectedName == null) return null;
    return StockService.instance
        .stockByNameFor(gudangOutletId)[_selectedName]
        ?.unit;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today.subtract(const Duration(days: 30)),
      lastDate: today,
      helpText: 'Tanggal stok masuk',
    );
    if (picked != null) setState(() => _date = picked);
  }

  /// "＋ Bahan baru": nama + satuan baku + harga + ambang.
  /// Dibuat LANGSUNG di gudang (bukan gerai aktif).
  Future<void> _addNewItem() async {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final thresholdCtrl = TextEditingController();
    String unit = 'kg';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Bahan baru'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nama bahan (mis. Teh Kering)',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: unit,
                decoration: const InputDecoration(
                  labelText: 'Satuan baku',
                ),
                items: [
                  for (final u in stockUnits)
                    DropdownMenuItem(value: u, child: Text(u)),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => unit = v);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Harga per satuan (Rp, opsional)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: thresholdCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Batas minimum ($unit, opsional)',
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
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama bahan tidak boleh kosong.')),
      );
      return;
    }
    final price = int.tryParse(priceCtrl.text.trim()) ?? 0;
    final threshold =
        parseQty(thresholdCtrl.text) ?? 0;
    await StockService.instance.ensureStockItem(
      gudangOutletId,
      name,
      unit,
      lowThreshold: threshold,
    );
    if (price > 0) {
      await StockService.instance.setCostFor(
        gudangOutletId,
        name,
        price.toDouble(),
      );
    }
    if (mounted) {
      setState(() => _selectedName = name);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bahan $name ditambahkan ke gudang.')),
      );
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _selectedName;
    final unit = _selectedUnit;
    if (name == null || unit == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih bahan dulu.')),
      );
      return;
    }
    final qty = parseQty(_qtyCtrl.text);
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Jumlah harus angka > 0.')),
      );
      return;
    }
    final totalPrice = int.tryParse(_priceCtrl.text.trim()) ?? 0;
    if (totalPrice < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harga beli tidak boleh negatif.')),
      );
      return;
    }
    setState(() => _saving = true);
    final record = await PackageService.instance.recordStockIn(
      stockName: name,
      unit: unit,
      qty: qty,
      totalPrice: totalPrice,
      supplier: _supplierCtrl.text.trim(),
      date: _date,
      note: _noteCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (record == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tidak bisa disimpan — cek tanggal (maks 30 hari mundur, '
            'tidak boleh masa depan).',
          ),
        ),
      );
      return;
    }
    _qtyCtrl.clear();
    _priceCtrl.clear();
    _supplierCtrl.clear();
    _noteCtrl.clear();
    unawaited(SyncService.instance.syncNow());
    await _loadPending();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Masuk: ${qtyText(qty)} $unit $name ke gudang.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Stok Masuk')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          StockService.instance,
          PackageService.instance,
        ]),
        builder: (context, _) {
          final names = _gudangNames;
          final unit = _selectedUnit;
          final history = PackageService.instance.stockIns;
          final shown = _showAll ? history : history.take(3).toList();
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Catat stok masuk gudang',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Stok gudang bertambah otomatis. Harga beli '
                        'total mengubah harga per satuan bahan itu.',
                        style: TextStyle(color: SukaTeaColors.muted),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: _selectedName,
                        decoration: const InputDecoration(
                          labelText: 'Bahan',
                        ),
                        items: [
                          for (final n in names)
                            DropdownMenuItem(value: n, child: Text(n)),
                        ],
                        onChanged: (v) =>
                            setState(() => _selectedName = v),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _addNewItem,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Bahan baru'),
                        ),
                      ),
                      TextField(
                        controller: _qtyCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Jumlah',
                          suffixText: unit,
                          hintText: 'mis. 2,5',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _priceCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Harga beli total (Rp, opsional)',
                          hintText: 'kosong = harga tidak berubah',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _supplierCtrl,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Supplier (opsional)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: _pickDate,
                        borderRadius: BorderRadius.circular(12),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Tanggal',
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
                      const SizedBox(height: 12),
                      TextField(
                        controller: _noteCtrl,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Catatan (opsional)',
                        ),
                      ),
                      const SizedBox(height: 16),
                      GudangPrimaryButton(
                        label: _saving ? 'Menyimpan…' : 'Simpan',
                        onPressed: _saving ? null : _save,
                        icon: Icons.inventory_2,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: GudangSectionTitle('Riwayat stok masuk'),
                  ),
                  if (history.length > 3)
                    TextButton(
                      onPressed: () =>
                          setState(() => _showAll = !_showAll),
                      child: Text(
                        _showAll ? 'Sembunyikan' : 'Lihat semua',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (history.isEmpty)
                const GudangEmptyState(
                  message:
                      'Belum ada stok masuk. Gudang masih kosong — '
                      'catat stok masuk dulu sebelum kirim ke gerai.',
                )
              else
                for (final r in shown)
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
                                  '${qtyText(r.qty)} ${r.unit} ${r.stockName}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              Chip(
                                label: Text(
                                  _pendingIds.contains(r.id)
                                      ? 'Menunggu sinkron'
                                      : 'Terkirim',
                                ),
                                backgroundColor: _pendingIds.contains(r.id)
                                    ? SukaTeaColors.pillAmberBg
                                    : SukaTeaColors.emeraldSoft,
                                labelStyle: TextStyle(
                                  color: _pendingIds.contains(r.id)
                                      ? SukaTeaColors.amber
                                      : SukaTeaColors.emeraldDark,
                                  fontWeight: FontWeight.w600,
                                ),
                                side: BorderSide.none,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${r.date.day}/${r.date.month}/${r.date.year}'
                            '${r.supplier.isNotEmpty ? ' • ${r.supplier}' : ''}'
                            '${r.totalPrice > 0 ? ' • ${formatRupiah(r.totalPrice)}' : ''}',
                            style: const TextStyle(
                              color: SukaTeaColors.muted,
                            ),
                          ),
                          if (r.note.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              r.note,
                              style: const TextStyle(
                                color: SukaTeaColors.muted,
                                fontSize: 12,
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
