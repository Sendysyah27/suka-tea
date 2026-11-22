import 'package:flutter/material.dart';

import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';

/// Kelola Menu — HANYA Owner. Menu, harga, dan foto produk di-custom di
/// dalam app (bukan hardcode). Kasir read-only.
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
              child: ListTile(
                title: Text(_canEdit
                    ? 'Kelola Menu (Owner)'
                    : 'Katalog — Kasir hanya bisa melihat'),
                subtitle: const Text(
                  'Harga dan foto di-custom di sini. Foto di-upload ke Supabase Storage (M1).',
                ),
                trailing: _canEdit
                    ? FilledButton.icon(
                        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Tambah menu — M1')),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('Tambah'),
                      )
                    : null,
              ),
            ),
          );
        }
        final p = _products[index - 1];
        return Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.local_drink)),
            title: Text(p.name),
            subtitle: Text(
              '${p.category} • ${formatRupiah(p.variants.first.price)} / '
              '${formatRupiah(p.variants.last.price)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
