import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/product_photo.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/menu_service.dart';
import '../../data/models.dart';
import '../../data/outlet_service.dart';
import '../../data/seed_menu.dart';
import '../pin/pin_dialog.dart';
import '../resep/resep_page.dart';
import '../topping/topping_page.dart';
import 'product_photo_service.dart';

/// Kelola Menu — HANYA Owner. Menu, harga, dan foto produk di-custom di
/// dalam app (bukan hardcode). Kasir read-only. Desain v2: thumb 56px
/// + kartu radius 20.
///
/// Menu dibaca dari MenuService (SATU sumber dengan Kasir): edit di sini
/// langsung tampil di Kasir dan TERSIMPAN di LocalProducts (restart
/// tidak hilang). Owner bisa, per produk:
/// - tambah produk baru (form nyata: nama, kategori, harga 22oz, foto)
/// - ubah nama, kategori, harga 22oz (_editProduct)
/// - ganti foto dari 20 foto poster bawaan (_changePhoto)
/// - ganti foto dari kamera/galeri (Batch C3): upload ke Supabase
///   Storage lewat Edge Function + bukti PIN Owner; hanya untuk produk
///   yang sudah ada (id dipakai sebagai nama file di Storage).
/// - hapus foto → kembali ke ikon placeholder
/// - hapus produk (dengan konfirmasi)
/// - toggle Aktif/Habis (produk habis tidak bisa ditambah ke keranjang)
/// - cari produk lewat TextField
/// Foto custom dari kamera/galeri (Batch C3) hanya untuk produk yang
/// sudah tersimpan — produk baru pakai foto bawaan dulu, lalu ganti
/// foto custom lewat thumb / menu ⋮ sesudah disimpan.
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
    // Batch C8.2 WS7: SATU harga — 22oz (tidak ada Reguler/Jumbo).
    final harga = TextEditingController(
      text: product?.variants.first.price.toString() ?? '',
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
                  controller: harga,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Harga (Rp) — 22oz',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Foto produk',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final picked = await _pickPhotoFor(
                      product: product,
                      selected: photoUrl,
                    );
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
                  product == null
                      ? 'Ketuk foto untuk memilih dari 20 foto bawaan. '
                          'Foto kamera/galeri bisa diatur sesudah produk disimpan.'
                      : 'Ketuk foto untuk mengganti (kamera / galeri / foto bawaan).',
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
    final price =
        int.tryParse(harga.text) ?? product?.variants.first.price ?? 0;
    if (price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harga harus > 0.')),
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
        ProductVariant(id: '${id}_22oz', name: '22oz', sizeOz: 22, price: price),
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

  /// Pilih sumber foto untuk produk yang SUDAH ada (punya id):
  /// Kamera / Galeri (upload ke Storage) atau Foto bawaan (20 poster).
  /// Produk baru (product null) belum punya id untuk nama file di
  /// Storage — langsung ke pemilih foto bawaan saja.
  /// Mengembalikan URL/path foto baru, '' = hapus foto, null = batal
  /// (termasuk bila upload gagal — foto lama tetap).
  Future<String?> _pickPhotoFor({Product? product, String? selected}) async {
    if (product == null) return _pickPhoto(selected);
    final source = await _photoSourceDialog();
    if (source == null) return null;
    if (source == 'bundled') return _pickPhoto(selected);
    final url = await _uploadPhoto(
      product: product,
      source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
    );
    return url;
  }

  /// Dialog pilih sumber foto: 'camera' | 'gallery' | 'bundled' | null.
  Future<String?> _photoSourceDialog() async {
    return showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ganti foto produk'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Ambil dari Kamera'),
              onTap: () => Navigator.of(context).pop('camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Pilih dari Galeri'),
              onTap: () => Navigator.of(context).pop('gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.grid_view),
              title: const Text('Foto bawaan (20 poster)'),
              onTap: () => Navigator.of(context).pop('bundled'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Batal'),
          ),
        ],
      ),
    );
  }

  /// Alur upload foto custom (Batch C3): bukti PIN Owner dulu
  /// (dialog PIN — PIN diteruskan sekali ke server, tidak disimpan),
  /// lalu pilih foto (diperkecil image_picker: max 1024px, quality
  /// 85), lalu upload lewat Edge Function. Mengembalikan URL publik
  /// atau null bila batal/gagal. SnackBar memberi tahu hasilnya.
  /// Dialog loading tidak bisa ditutup tombol kembali (PopScope) dan
  /// pasti ditutup di semua jalur sesudah upload selesai.
  Future<String?> _uploadPhoto({
    required Product product,
    required ImageSource source,
  }) async {
    // 1. Bukti Owner — PIN diverifikasi server, diteruskan sekali.
    // ownerPin di-assign di dalam closure onPinVerified, jadi TIDAK
    // ter-promote: cek null + `!` wajib di tiap pemakaian (pelajaran
    // CI v27.1).
    String? ownerPin;
    final pinOk = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(
        outletId: OutletService.instance.currentOutletId,
        onPinVerified: (pin) => ownerPin = pin,
      ),
    );
    if (pinOk != true || ownerPin == null || !mounted) return null;

    // 2. Pilih foto (batal = null, foto lama tetap).
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return null;

    // 3. Upload dengan dialog loading (pasti ditutup di semua jalur).
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Expanded(child: Text('Mengunggah foto…')),
              ],
            ),
          ),
        ),
      ),
    );
    String? url;
    try {
      final bytes = await picked.readAsBytes();
      url = await ProductPhotoService.instance.uploadPhoto(
        outletId: OutletService.instance.currentOutletId,
        productId: product.id,
        bytes: bytes,
        ownerPin: ownerPin!,
      );
    } catch (e) {
      debugPrint('Upload foto gagal: $e');
      url = null;
    }
    if (!mounted) return null;
    Navigator.of(context).pop(); // tutup dialog loading
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Foto gagal diunggah — periksa koneksi / Edge Function belum di-deploy.',
          ),
        ),
      );
      return null;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Foto ${product.name} diperbarui.')),
    );
    return url;
  }

  Future<void> _changePhoto(Product product) async {
    final picked = await _pickPhotoFor(
      product: product,
      selected: product.photoUrl,
    );
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
                                  // Batch C8.2 WS7: harga tunggal 22oz.
                                  '${formatRupiah(p.variants.first.price)}'
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
