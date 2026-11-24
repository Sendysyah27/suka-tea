import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../data/recipe_logic.dart';
import '../../data/stock_service.dart';

/// Editor resep — HANYA Owner, dibuka dari Kelola Menu → tombol Resep.
/// Satu produk, SATU seksi 22oz (Batch C8.2 WS7 — tidak ada lagi
/// Reguler 16oz). Tiap baris: dropdown bahan + jumlah per cup +
/// satuan + hapus. Satu bahan max 1x per varian (dropdown
/// menyembunyikan bahan yang sudah dipakai).
/// Perubahan lokal dulu (Drift), sinkron Supabase di M1.
class ResepPage extends StatefulWidget {
  const ResepPage({super.key, required this.product});

  final Product product;

  @override
  State<ResepPage> createState() => _ResepPageState();
}

class _ResepPageState extends State<ResepPage> {
  late List<RecipeLine> _lines;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final service = StockService.instance;
    // Salinan yang bisa diedit — StockService baru ditulis saat Simpan.
    // Batch C8.2 WS7: SATU resep — varian 22oz produk ini.
    _lines = service.recipesFor(widget.product.variants.first.id).toList();
  }

  /// Bahan yang boleh dipilih di dropdown baris ini: semua stok yang
  /// belum dipakai di varian ini, ditambah bahan baris ini sendiri.
  List<String> _availableNames(List<RecipeLine> lines, String current) {
    final used = lines.map((l) => l.stockName).toSet()..remove(current);
    return [
      for (final s in StockService.instance.levels)
        if (!used.contains(s.name)) s.name,
    ];
  }

  String _unitOf(String stockName) {
    final found = StockService.instance.stockByName[stockName];
    return found?.unit ?? '';
  }

  /// Tampilkan angka ringkas: 1 -> "1", 0.015 -> "0,015" (koma Indonesia).
  String _qtyText(double v) {
    var s = v.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s.replaceAll('.', ',');
  }

  /// Parse input Indonesia ("0,5" atau "0.5"). null = tidak valid.
  double? _parseQty(String raw) {
    final v = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (v == null || v <= 0) return null;
    return v;
  }

  void _addLine(List<RecipeLine> lines) {
    final options = _availableNames(lines, '');
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Semua bahan sudah dipakai di varian ini.')),
      );
      return;
    }
    setState(() {
      lines.add(RecipeLine(stockName: options.first, qty: 0.01));
    });
  }

  Future<void> _save() async {
    if (_lines.any((l) => l.qty <= 0 || l.stockName.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Jumlah harus lebih dari 0 di semua baris.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    await StockService.instance.setRecipe(
      widget.product.variants.first.id,
      _lines,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    // SnackBar dulu baru pop: SnackBar menempel di ScaffoldMessenger
    // root (MaterialApp) jadi tetap tampil di Kelola Menu sesudah pop;
    // kalau dibalik, context halaman yang sudah di-pop tidak valid.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Resep ${widget.product.name} disimpan.')),
    );
    Navigator.of(context).pop(true);
  }

  Widget _variantSection({
    required String title,
    required List<RecipeLine> lines,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 12),
            if (lines.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Belum ada bahan — tambah di bawah.',
                  style: TextStyle(color: SukaTeaColors.muted),
                ),
              ),
            for (var i = 0; i < lines.length; i++)
              Padding(
                key: ValueKey('${widget.product.id}_$title${lines[i].stockName}'),
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        initialValue: lines[i].stockName,
                        decoration:
                            const InputDecoration(labelText: 'Bahan'),
                        items: [
                          for (final name
                              in _availableNames(lines, lines[i].stockName))
                            DropdownMenuItem(value: name, child: Text(name)),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            lines[i] =
                                lines[i].copyWith(stockName: v);
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        initialValue: _qtyText(lines[i].qty),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Jumlah',
                          suffixText: _unitOf(lines[i].stockName),
                        ),
                        onChanged: (raw) {
                          final v = _parseQty(raw);
                          if (v != null) {
                            lines[i] = lines[i].copyWith(qty: v);
                          }
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: 'Hapus bahan',
                      icon: const Icon(Icons.delete_outline),
                      color: SukaTeaColors.danger,
                      onPressed: () => setState(() => lines.removeAt(i)),
                    ),
                  ],
                ),
              ),
            OutlinedButton.icon(
              onPressed: () => _addLine(lines),
              icon: const Icon(Icons.add),
              label: const Text('Tambah bahan'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Resep — ${widget.product.name}')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Jumlah = pemakaian per 1 cup. Tiap penjualan otomatis '
                  'memotong stok bahan sesuai resep ini.',
                  style: TextStyle(color: SukaTeaColors.muted),
                ),
              ),
            ),
          ),
          _variantSection(
            title: '22oz',
            lines: _lines,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
            child: Text(
              _saving ? 'Menyimpan…' : 'Simpan resep',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
