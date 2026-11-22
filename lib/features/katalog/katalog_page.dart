import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';

/// Kelola Menu — HANYA Owner. Menu, harga, dan foto produk di-custom di
/// dalam app (bukan hardcode). Kasir read-only. Desain v2: thumb 56px
/// blok mint + kartu radius 20.
class KatalogPage extends StatefulWidget {
  const KatalogPage({super.key, required this.role});

  final AppRole role;

  @override
  State<KatalogPage> createState() => _KatalogPageState();
}

class _KatalogPageState extends State<KatalogPage> {
  late List<Product> _products;

  @override
  void initState() {
    super.initState();
    _products = seedMenu();
  }

  bool get _canEdit => widget.role.canManageMenu;

  Future<void> _editPrice(Product product) async {
    final reguler = TextEditingController(
      text: product.variants.first.price.toString(),
    );
    final jumbo = TextEditingController(
      text: product.variants.last.price.toString(),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Ubah harga — ${product.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: reguler,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Reguler (Rp)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: jumbo,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Jumbo (Rp)'),
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
    final r = int.tryParse(reguler.text) ?? product.variants.first.price;
    final j = int.tryParse(jumbo.text) ?? product.variants.last.price;
    setState(() {
      final i = _products.indexWhere((p) => p.id == product.id);
      _products[i] = Product(
        id: product.id,
        name: product.name,
        category: product.category,
        photoUrl: product.photoUrl,
        variants: [
          ProductVariant(id: '${product.id}_r', name: 'Reguler', sizeOz: 16, price: r),
          ProductVariant(id: '${product.id}_j', name: 'Jumbo', sizeOz: 22, price: j),
        ],
      );
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Harga ${product.name} diperbarui (lokal — sinkron Supabase di M1).')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _products.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Kelola Menu',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Harga dan foto di-custom di sini. Foto di-upload ke Supabase Storage (M1).',
                            style: TextStyle(color: SukaTeaColors.muted),
                          ),
                        ],
                      ),
                    ),
                    if (_canEdit)
                      FilledButton.icon(
                        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Tambah menu — M1')),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('Tambah'),
                      )
                    else
                      const Chip(label: Text('Kasir: lihat saja')),
                  ],
                ),
              ),
            ),
          );
        }
        final p = _products[index - 1];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: SukaTeaColors.emeraldSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.local_drink,
                    color: SukaTeaColors.emerald,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${p.category} • ${formatRupiah(p.variants.first.price)} / '
                        '${formatRupiah(p.variants.last.price)}',
                        style: const TextStyle(color: SukaTeaColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Foto produk',
                  icon: const Icon(Icons.photo_camera),
                  onPressed: _canEdit
                      ? () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Upload foto — kamera/galeri, M1')),
                          )
                      : null,
                ),
                IconButton(
                  tooltip: 'Ubah harga',
                  icon: const Icon(Icons.edit),
                  onPressed: _canEdit ? () => _editPrice(p) : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
