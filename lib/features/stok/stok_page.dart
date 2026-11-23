import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/models.dart';
import '../../data/stock_service.dart';

/// Stok bahan baku — dibaca dari StockService (Drift + seed), bukan lagi
/// seed statis. Desain v2: progress bar vs ambang + pill status.
/// Bar penuh = 3x ambang menipis (skala tampilan, bukan data baru).
/// Owner: ketuk kartu untuk ubah jumlah + ambang, FAB "+" tambah bahan.
/// Kasir: read-only.
class StokPage extends StatefulWidget {
  const StokPage({super.key, required this.role});

  final AppRole role;

  @override
  State<StokPage> createState() => _StokPageState();
}

class _StokPageState extends State<StokPage> {
  String _filter = 'Semua';

  bool get _canEdit => widget.role.canManageStock;

  /// Format jumlah: 120 -> "120", 2.5 -> "2,5" (koma Indonesia).
  String _qtyText(double v) {
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    var s = v.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s.replaceAll('.', ',');
  }

  double? _parseQty(String raw) {
    final v = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (v == null || v < 0) return null;
    return v;
  }

  Future<void> _editStock(StockItem item) async {
    final qty = TextEditingController(text: _qtyText(item.qty));
    final ambang =
        TextEditingController(text: _qtyText(item.lowThreshold));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Ubah stok — ${item.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qty,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  InputDecoration(labelText: 'Jumlah (${item.unit})'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ambang,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Ambang menipis (${item.unit})',
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
    final newQty = _parseQty(qty.text);
    final newAmbang = _parseQty(ambang.text);
    if (newQty == null || newAmbang == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Jumlah dan ambang harus angka ≥ 0.')),
      );
      return;
    }
    await StockService.instance.updateStock(item.name, newQty, newAmbang);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Stok ${item.name} diperbarui.')),
      );
    }
  }

  /// Ubah harga per satuan satu bahan (HANYA Owner — Batch C1b).
  /// Harga ini yang dipakai menghitung HPP di Keuangan/Laporan.
  /// Input angka bulat rupiah (digits only); -1 = belum diatur
  /// (tidak bisa diinput — kosongkan field untuk Rp0 = gratis).
  Future<void> _editCost(StockItem item) async {
    final cost = TextEditingController(
      text: item.costPerUnit >= 0 ? item.costPerUnit.round().toString() : '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Harga bahan — ${item.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: cost,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Harga per ${item.unit} (Rp)',
                hintText: 'Contoh: 120000',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Harga ini dipakai menghitung HPP di Keuangan/Laporan. '
              'Kosongkan untuk Rp0 (bahan gratis).',
              style: TextStyle(color: SukaTeaColors.muted, fontSize: 12),
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
    final raw = cost.text.trim();
    final newCost = raw.isEmpty ? 0.0 : double.tryParse(raw);
    if (newCost == null || !StockService.isValidCost(newCost)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harga harus angka ≥ 0.')),
      );
      return;
    }
    final ok = await StockService.instance.updateCost(item.name, newCost);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Harga ${item.name} diperbarui: '
                  '${formatRupiah(newCost.round())} / ${item.unit}.'
              : 'Harga ${item.name} gagal disimpan.',
        ),
      ),
    );
  }

  Future<void> _addStock() async {
    final name = TextEditingController();
    final qty = TextEditingController();
    final ambang = TextEditingController();
    var unit = 'kg';
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tambah bahan baru'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Nama bahan'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: unit,
                decoration: const InputDecoration(labelText: 'Satuan'),
                items: const [
                  DropdownMenuItem(value: 'kg', child: Text('kg')),
                  DropdownMenuItem(value: 'pcs', child: Text('pcs')),
                ],
                onChanged: (v) {
                  if (v != null) unit = v;
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: qty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Jumlah awal'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ambang,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Ambang menipis'),
              ),
            ],
          ),
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
    final newName = name.text.trim();
    final newQty = _parseQty(qty.text);
    final newAmbang = _parseQty(ambang.text);
    if (newName.isEmpty || newQty == null || newAmbang == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nama harus diisi, jumlah dan ambang harus angka ≥ 0.'),
        ),
      );
      return;
    }
    final ok = await StockService.instance.addStockItem(
      newName,
      unit,
      newQty,
      newAmbang,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Bahan $newName ditambahkan.'
              : 'Bahan $newName sudah ada — ubah yang ada saja.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // FAB hanya Owner; Kasir read-only.
      floatingActionButton: _canEdit
          ? TapFeedback(
              child: FloatingActionButton(
                onPressed: _addStock,
                tooltip: 'Tambah bahan baru',
                backgroundColor: SukaTeaColors.emerald,
                foregroundColor: Colors.white,
                child: const Icon(Icons.add),
              ),
            )
          : null,
      body: ListenableBuilder(
        listenable: StockService.instance,
        builder: (context, _) {
          final allItems = StockService.instance.levels;
          if (allItems.isEmpty) {
            return const Center(
              child: Text(
                'Stok belum siap.\nTutup lalu buka lagi tab ini.',
                textAlign: TextAlign.center,
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            );
          }
          final items = _filter == 'Menipis'
              ? allItems.where((s) => s.isLow).toList()
              : allItems;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(
                  children: [
                    for (final f in const ['Semua', 'Menipis'])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            f == 'Menipis'
                                ? 'Menipis (${allItems.where((s) => s.isLow).length})'
                                : f,
                          ),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                      ),
                  ],
                ),
              ),
              // Petunjuk singkat (HANYA Owner): harga bahan dipakai HPP.
              if (_canEdit)
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Harga bahan dipakai menghitung HPP di Keuangan — '
                      'ketuk harga di tiap kartu untuk mengubahnya.',
                      style: TextStyle(
                        color: SukaTeaColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              if (items.isEmpty)
                const Expanded(
                  child: Center(
                    child: Text(
                      'Tidak ada bahan yang menipis.',
                      style: TextStyle(color: SukaTeaColors.muted),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
              final StockItem item = items[i];
              final fraction =
                  (item.qty / (item.lowThreshold * 3)).clamp(0.0, 1.0);
              final usedIn = StockService.instance.usageCount(item.name);
              return Card(
                child: InkWell(
                  onTap: _canEdit ? () => _editStock(item) : null,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Chip(
                              label: Text(item.isLow ? 'Menipis' : 'Aman'),
                              backgroundColor: item.isLow
                                  ? SukaTeaColors.pillAmberBg
                                  : SukaTeaColors.emeraldSoft,
                              labelStyle: TextStyle(
                                color: item.isLow
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
                          '${_qtyText(item.qty)} ${item.unit} • ambang '
                          '${_qtyText(item.lowThreshold)} ${item.unit}',
                          style: const TextStyle(color: SukaTeaColors.muted),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Dipakai di: $usedIn varian',
                          style: const TextStyle(
                            color: SukaTeaColors.muted,
                            fontSize: 12,
                          ),
                        ),
                        // Harga bahan (Batch C1b): HANYA Owner — Kasir
                        // tidak melihat/mengubahnya (preseden
                        // ProductVariant.cost). Ketuk barisnya untuk ubah.
                        if (_canEdit) ...[
                          const SizedBox(height: 4),
                          InkWell(
                            onTap: () => _editCost(item),
                            borderRadius: BorderRadius.circular(8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.costPerUnit >= 0
                                        ? 'Harga: ${formatRupiah(item.costPerUnit.round())} / ${item.unit}'
                                        : 'Harga: belum diatur',
                                    style: const TextStyle(
                                      color: SukaTeaColors.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.edit_outlined,
                                  size: 16,
                                  color: SukaTeaColors.muted,
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 8,
                            backgroundColor: SukaTeaColors.leafBg,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              item.isLow
                                  ? SukaTeaColors.amber
                                  : SukaTeaColors.emerald,
                            ),
                          ),
                        ),
                      ],
                    ),
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
