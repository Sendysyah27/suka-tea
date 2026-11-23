import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/product_photo.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/menu_service.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';
import '../resep/resep_page.dart';
import '../topping/topping_page.dart';

/// Kelola Menu — HANYA Owner. Menu, harga, dan foto produk di-custom di
/// dalam app (bukan hardcode). Kasir read-only. Desain v2: thumb 56px
/// + kartu radius 20.
///
/// Menu dibaca dari MenuService (SATU sumber dengan Kasir): edit di sini
/// langsung tampil di Kasir dan TERSIMPAN di LocalProducts (restart
/// tidak hilang). Owner bisa, per produk:
/// - tambah produk baru (form nyata: nama, kategori, harga R/J, foto)
/// - ubah nama, kategori, harga Reguler, harga Jumbo (_editProduct)
/// - ganti foto dari 20 foto poster bawaan (_changePhoto)
/// - hapus foto → kembali ke ikon placeholder
/// - hapus produk (dengan konfirmasi)
/// - toggle Aktif/Habis (produk habis tidak bisa ditambah ke keranjang)
/// - cari produk lewat TextField
/// Upload foto sendiri dari kamera/galeri masih M1.
class KatalogPage extends StatefulWidget {
  const KatalogPage({super.key, required this.role});

  final AppRole role;

  @override
  State<KatalogPage> createState() => _KatalogPageState();
}

class _KatalogPageState extends State<KatalogPage> {
  String _query = '';

  bool get _canEdit => widget.role.canManageMenu;

  List<Product> get _visible {
    final products = MenuService.instance.products;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return products;
    return products.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  /// Form produk — dipakai tambah (product null) dan ubah (product ada).
  /// Mengembalikan Product baru / yang sudah diubah, atau null bila batal.
  Future<Product?> _productForm({Product? product}) async {
    final name = TextEditingController(text: product?.name ?? '');
    final reguler = TextEditingController(
      text: product?.variants.first.price.toString() ?? '',
    );
    final jumbo = TextEditingController(
      text: product?.variants.last.price.toString() ?? '',
    );
    var category = product?.category ?? menuCategories.first;
    var photoUrl = product?.photoUrl;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            product == null ? 'Tambah produk' : 'Ubah produk — ${product.name}',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nama produk'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue:
                      menuCategories.contains(category) ? category : null,
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
                  decoration:
                      const InputDecoration(labelText: 'Reguler (Rp)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: jumbo,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Jumbo (Rp)'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Foto produk',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final picked = await _pickPhoto(photoUrl);
                    if (picked != null) {
                      setDialogState(() => photoUrl = picked);
                    }
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: ProductPhoto(
                    photoUrl: photoUrl,
                    width: double.infinity,
                    height: 80,
                    borderRadius: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  photoUrl == null
                      ? 'Ketuk foto untuk memilih dari 20 foto bawaan.'
                      : 'Ketuk foto untuk mengganti.',
                  style: const TextStyle(color: SukaTeaColors.muted),
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
      ),
    );
    if (saved != true || !mounted) return null;
    final newName = name.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama produk harus diisi.')),
      );
      return null;
    }
    final r = int.tryParse(reguler.text) ?? product?.variants.first.price ?? 0;
    final j = int.tryParse(jumbo.text) ?? product?.variants.last.price ?? 0;
    if (r <= 0 || j <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harga Reguler dan Jumbo harus > 0.')),
      );
      return null;
    }
    final id = product?.id ?? _newProductId(newName);
    return Product(
      id: id,
      name: newName,
      category: category,
      photoUrl: photoUrl,
      isActive: product?.isActive ?? true,
      variants: [
        ProductVariant(id: '${id}_r', name: 'Reguler', sizeOz: 16, price: r),
        ProductVariant(id: '${id}_j', name: 'Jumbo', sizeOz: 22, price: j),
      ],
    );
  }

  /// Id unik dari nama: slug + stempel waktu (supaya dua produk
  /// bernama sama tidak bentrok). Resep produk baru masih kosong —
  /// Owner menambahkannya lewat tombol Resep.
  String _newProductId(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty ? 'produk' : slug;
    return '$base-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<void> _addProduct() async {
    final product = await _productForm();
    if (product == null || !mounted) return;
    await MenuService.instance.addProduct(product);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${product.name} ditambahkan ke menu.')),
      );
    }
  }

  Future<void> _editProduct(Product product) async {
    final updated = await _productForm(product: product);
    if (updated == null || !mounted) return;
    await MenuService.instance.updateProduct(updated);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${updated.name} diperbarui.')),
      );
    }
  }

  /// Buka editor resep produk. Setelah kembali, refresh (resep tidak
  /// mengubah tampilan kartu, tapi setState menjaga konsistensi).
  Future<void> _openResep(Product product) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ResepPage(product: product)),
    );
    if (mounted) setState(() {});
  }

  /// Buka Kelola Topping (Batch C1) — HANYA Owner. Topping yang
  /// dipilih kasir di sheet opsi produk dikelola di sana.
  Future<void> _openToppings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ToppingPage(role: widget.role),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Pemilih foto dari 20 foto poster bawaan. '' = hapus foto,
  /// null = batal.
  Future<String?> _pickPhoto(String? selected) async {
    return showDialog<String?>(
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
  }

  Future<void> _changePhoto(Product product) async {
    final picked = await _pickPhoto(product.photoUrl);
    if (picked == null || !mounted) return;
    await MenuService.instance.updateProduct(
      Product(
        id: product.id,
        name: product.name,
        category: product.category,
        photoUrl: picked.isEmpty ? null : picked,
        variants: product.variants,
        isActive: product.isActive,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            picked.isEmpty
                ? 'Foto ${product.name} dihapus.'
                : 'Foto ${product.name} diganti.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteProduct(Product product) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus ${product.name}?'),
        content: const Text(
          'Produk hilang dari Kasir dan Kelola Menu. '
          'Riwayat penjualan yang sudah ada tidak ikut terhapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: SukaTeaColors.danger,
            ),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await MenuService.instance.removeProduct(product.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${product.name} dihapus dari menu.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MenuService.instance,
      builder: (context, _) {
        final products = _visible;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                onChanged: (q) => setState(() => _query = q),
                decoration: const InputDecoration(
                  hintText: 'Cari produk…',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: products.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    // Header "Kelola Menu" + tombol "+ Tambah menu"
                    // full-width 56px di bawahnya (FigCraft frame 04).
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Card(
                            child: Padding(
                              padding: EdgeInsets.all(16),
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
                                    'Perubahan langsung tampil di Kasir dan tersimpan.',
                                    style: TextStyle(
                                      color: SukaTeaColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_canEdit)
                            TapFeedback(
                              child: FilledButton.icon(
                                onPressed: _addProduct,
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(0, 56),
                                ),
                                icon: SvgPicture.asset(
                                  AppIcons.tambah,
                                  width: 20,
                                  height: 20,
                                  colorFilter: const ColorFilter.mode(
                                    Colors.white,
                                    BlendMode.srcIn,
                                  ),
                                ),
                                label: const Text('+ Tambah menu'),
                              ),
                            )
                          else
                            const Chip(label: Text('Kasir: lihat saja')),
                          // Kelola Topping (Batch C1): topping di sheet
                          // opsi produk dikelola di halaman sendiri.
                          // HANYA Owner — Kasir tidak melihat tombolnya.
                          if (_canEdit) ...[
                            const SizedBox(height: 12),
                            TapFeedback(
                              child: OutlinedButton.icon(
                                onPressed: _openToppings,
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 56),
                                ),
                                icon: const Icon(Icons.local_drink_outlined),
                                label: const Text('Kelola topping'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }
                  final p = products[index - 1];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          InkWell(
                            onTap: _canEdit ? () => _changePhoto(p) : null,
                            borderRadius: BorderRadius.circular(12),
                            child: ProductPhoto(
                              photoUrl: p.photoUrl,
                              width: 48,
                              height: 48,
                              borderRadius: 12,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.name,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${formatRupiah(p.variants.first.price)} / '
                                  '${formatRupiah(p.variants.last.price)}'
                                  '${p.isActive ? '' : ' • Habis'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: p.isActive
                                        ? SukaTeaColors.muted
                                        : SukaTeaColors.danger,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Pill "Resep" outline 64x32 (FigCraft 04).
                          InkWell(
                            onTap: _canEdit ? () => _openResep(p) : null,
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              width: 64,
                              height: 32,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: SukaTeaColors.emerald,
                                ),
                              ),
                              child: const Text(
                                'Resep',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: SukaTeaColors.emerald,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Toggle Aktif/Habis (FigCraft 04: 44x24).
                          // Switch bawaan ~59px lebar — diskala 0.8
                          // (~47px) supaya muat di baris tanpa
                          // mengorbankan kolom nama.
                          Transform.scale(
                            scale: 0.8,
                            child: Switch(
                              value: p.isActive,
                              onChanged: _canEdit
                                  ? (v) => MenuService.instance.setActive(
                                        p.id,
                                        v,
                                      )
                                  : null,
                            ),
                          ),
                          // Aksi lain (Ubah / Ganti foto / Hapus) di
                          // menu ⋮ — 5 IconButton berjejer membuat
                          // kolom nama terjepit di layar 390dp.
                          PopupMenuButton<String>(
                            tooltip: 'Aksi lainnya',
                            enabled: _canEdit,
                            icon: const Icon(Icons.more_vert),
                            onSelected: (value) {
                              switch (value) {
                                case 'edit':
                                  _editProduct(p);
                                case 'photo':
                                  _changePhoto(p);
                                case 'delete':
                                  _deleteProduct(p);
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('Ubah nama / kategori / harga'),
                              ),
                              const PopupMenuItem(
                                value: 'photo',
                                child: Text('Ganti foto produk'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Hapus produk'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
