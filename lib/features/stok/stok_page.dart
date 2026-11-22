import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/roles.dart';
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
          ? FloatingActionButton(
              onPressed: _addStock,
              tooltip: 'Tambah bahan baru',
              child: const Icon(Icons.add),
            )
          : null,
      body: ListenableBuilder(
        listenable: StockService.instance,
        builder: (context, _) {
          final items = StockService.instance.levels;
          if (items.isEmpty) {
            return const Center(
              child: Text(
                'Stok belum siap.\nTutup lalu buka lagi tab ini.',
                textAlign: TextAlign.center,
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            );
          }
          return ListView.builder(
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
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Chip(
                              label: Text(item.isLow ? 'Menipis' : 'Aman'),
                              backgroundColor: item.isLow
                                  ? const Color(0xFFFDF3E0)
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
          );
        },
      ),
    );
  }
}
