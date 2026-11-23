import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/topping_service.dart';

/// Kelola Topping — HANYA Owner. Dibuka dari Kelola Menu
/// ("Kelola topping"). Topping yang dipilih kasir di sheet opsi
/// produk berasal dari sini (bukan lagi const seed).
///
/// Nama topping HARUS sama dengan nama bahan stok:
/// - topping baru -> bahan stok otomatis dibuat (satuan "porsi",
///   qty 0 — Owner isi jumlah + harganya di halaman Stok).
/// - topping diganti nama -> nama bahan stok ikut diganti.
/// - topping dihapus -> bahan stoknya TETAP ADA.
/// Topping nonaktif disembunyikan dari sheet opsi (tidak dihapus).
class ToppingPage extends StatefulWidget {
  const ToppingPage({super.key, required this.role});

  final AppRole role;

  @override
  State<ToppingPage> createState() => _ToppingPageState();
}

class _ToppingPageState extends State<ToppingPage> {
  bool get _canEdit => widget.role.canManageToppings;

  /// Form topping — dipakai tambah (topping null) dan ubah.
  /// Mengembalikan (nama, harga) atau null bila batal.
  Future<(String, int)?> _toppingForm({ToppingItem? topping}) async {
    final name = TextEditingController(text: topping?.name ?? '');
    final price = TextEditingController(
      text: topping == null ? '' : topping.priceDelta.toString(),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          topping == null ? 'Tambah topping' : 'Ubah topping',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nama topping'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: price,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Harga tambahan (Rp)',
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
    if (saved != true || !mounted) return null;
    final cleanName = name.text.trim();
    final cleanPrice = int.tryParse(price.text) ?? -1;
    if (cleanName.isEmpty || cleanPrice < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nama harus diisi, harga harus angka ≥ 0.'),
        ),
      );
      return null;
    }
    return (cleanName, cleanPrice);
  }

  Future<void> _addTopping() async {
    final form = await _toppingForm();
    if (form == null || !mounted) return;
    final (name, price) = form;
    final ok = await ToppingService.instance.addTopping(name, price);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Topping $name ditambahkan (bahan stok dibuat, qty 0).'
              : 'Nama $name sudah dipakai topping lain.',
        ),
      ),
    );
  }

  Future<void> _editTopping(ToppingItem topping) async {
    final form = await _toppingForm(topping: topping);
    if (form == null || !mounted) return;
    final (name, price) = form;
    final ok = await ToppingService.instance.updateTopping(
      topping.id,
      name: name,
      priceDelta: price,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Topping $name diperbarui.'
              : 'Nama $name sudah dipakai topping / bahan lain.',
        ),
      ),
    );
  }

  Future<void> _deleteTopping(ToppingItem topping) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hapus topping ${topping.name}?'),
        content: const Text(
          'Topping hilang dari sheet pilihan produk. '
          'Bahan stoknya tetap ada di halaman Stok.',
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
    await ToppingService.instance.removeTopping(topping.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Topping ${topping.name} dihapus.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Kelola Topping',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
      ),
      floatingActionButton: _canEdit
          ? TapFeedback(
              child: FloatingActionButton(
                onPressed: _addTopping,
                tooltip: 'Tambah topping',
                backgroundColor: SukaTeaColors.emerald,
                foregroundColor: Colors.white,
                child: const Icon(Icons.add),
              ),
            )
          : null,
      body: ListenableBuilder(
        listenable: ToppingService.instance,
        builder: (context, _) {
          final toppings = ToppingService.instance.toppings;
          return Column(
            children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Topping di sheet pilihan produk',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Nama topping harus sama dengan nama bahan stok. '
                        'Topping baru otomatis dibuatkan bahannya '
                        '(satuan porsi, qty 0) — isi jumlah + harganya '
                        'di halaman Stok. Topping yang dihapus tidak '
                        'menghapus bahan stoknya.',
                        style: TextStyle(color: SukaTeaColors.muted),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: toppings.isEmpty
                    ? const Center(
                        child: Text(
                          'Belum ada topping.',
                          style: TextStyle(color: SukaTeaColors.muted),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: toppings.length,
                        itemBuilder: (context, i) {
                          final t = toppings[i];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          t.name,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '+${formatRupiah(t.priceDelta)}'
                                          '${t.active ? '' : ' • Nonaktif'}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: t.active
                                                ? SukaTeaColors.muted
                                                : SukaTeaColors.danger,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Toggle aktif/nonaktif (pola Katalog:
                                  // Switch diskala 0.8 supaya muat).
                                  Transform.scale(
                                    scale: 0.8,
                                    child: Switch(
                                      value: t.active,
                                      onChanged: _canEdit
                                          ? (v) => ToppingService.instance
                                              .setActive(t.id, v)
                                          : null,
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    tooltip: 'Aksi topping',
                                    enabled: _canEdit,
                                    icon: const Icon(Icons.more_vert),
                                    onSelected: (value) {
                                      switch (value) {
                                        case 'edit':
                                          _editTopping(t);
                                        case 'delete':
                                          _deleteTopping(t);
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      const PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Ubah nama / harga'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Hapus topping'),
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
      ),
    );
  }
}
