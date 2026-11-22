import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/product_photo.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';
import '../resep/resep_page.dart';

/// Kelola Menu — HANYA Owner. Menu, harga, dan foto produk di-custom di
/// dalam app (bukan hardcode). Kasir read-only. Desain v2: thumb 56px
/// + kartu radius 20.
///
/// Default: 20 produk poster (foto crop poster di assets/products/).
/// Owner bisa, per produk:
/// - ubah nama, kategori, harga Reguler, harga Jumbo (_editProduct)
/// - ganti foto dari 20 foto poster bawaan (_changePhoto)
/// - hapus foto → kembali ke ikon placeholder
/// Perubahan di sini lokal dulu (sinkron Supabase di M1); upload foto
/// sendiri dari kamera/galeri juga M1.
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

  void _replaceProduct(Product updated) {
    setState(() {
      final i = _products.indexWhere((p) => p.id == updated.id);
      if (i >= 0) _products[i] = updated;
    });
  }

  Future<void> _editProduct(Product product) async {
    final name = TextEditingController(text: product.name);
    final reguler = TextEditingController(
      text: product.variants.first.price.toString(),
    );
    final jumbo = TextEditingController(
      text: product.variants.last.price.toString(),
    );
    var category = product.category;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Ubah produk — ${product.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Nama produk'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: menuCategories.contains(category) ? category : null,
                decoration: const InputDecoration(labelText: 'Kategori'),
                items: [
                  for (final c in menuCategories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) {
                  if (v != null) category = v;
                },
              ),
              const SizedBox(height: 12),
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
    final newName = name.text.trim().isEmpty ? product.name : name.text.trim();
    final r = int.tryParse(reguler.text) ?? product.variants.first.price;
    final j = int.tryParse(jumbo.text) ?? product.variants.last.price;
    _replaceProduct(
      Product(
        id: product.id,
        name: newName,
        category: category,
        photoUrl: product.photoUrl,
        variants: [
          ProductVariant(id: '${product.id}_r', name: 'Reguler', sizeOz: 16, price: r),
          ProductVariant(id: '${product.id}_j', name: 'Jumbo', sizeOz: 22, price: j),
        ],
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$newName diperbarui (lokal — sinkron Supabase di M1).'),
      ),
    );
  }

  /// Buka editor resep produk. Setelah kembali, refresh (resep tidak
  /// mengubah tampilan kartu, tapi setState menjaga konsistensi).
  Future<void> _openResep(Product product) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ResepPage(product: product)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _changePhoto(Product product) async {
    final selected = product.photoUrl;
    final picked = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ganti foto produk'),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: bundledProductPhotos.length,
            itemBuilder: (context, i) {
              final photo = bundledProductPhotos[i];
              final isSelected = photo == selected;
              return InkWell(
                onTap: () => Navigator.of(context).pop(photo),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected
                          ? SukaTeaColors.emerald
                          : SukaTeaColors.border,
                      width: isSelected ? 3 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.asset(photo, fit: BoxFit.cover),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('Hapus foto'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Batal'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    _replaceProduct(
      Product(
        id: product.id,
        name: product.name,
        category: product.category,
        photoUrl: picked.isEmpty ? null : picked,
        variants: product.variants,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          picked.isEmpty
              ? 'Foto ${product.name} dihapus (lokal — sinkron Supabase di M1).'
              : 'Foto ${product.name} diganti (lokal — sinkron Supabase di M1).',
        ),
      ),
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
                            'Nama, kategori, harga, dan foto di-custom di sini. '
                            'Foto bawaan dari poster — upload foto sendiri ke Supabase Storage (M1).',
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
                InkWell(
                  onTap: _canEdit ? () => _changePhoto(p) : null,
                  borderRadius: BorderRadius.circular(14),
                  child: ProductPhoto(
                    photoUrl: p.photoUrl,
                    width: 56,
                    height: 56,
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
                  tooltip: 'Resep bahan per cup',
                  icon: const Icon(Icons.menu_book),
                  onPressed: _canEdit ? () => _openResep(p) : null,
                ),
                IconButton(
                  tooltip: 'Ganti foto produk',
                  icon: const Icon(Icons.photo_camera),
                  onPressed: _canEdit ? () => _changePhoto(p) : null,
                ),
                IconButton(
                  tooltip: 'Ubah nama / kategori / harga',
                  icon: const Icon(Icons.edit),
                  onPressed: _canEdit ? () => _editProduct(p) : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
