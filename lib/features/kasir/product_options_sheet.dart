import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';
import '../../data/topping_service.dart';

/// Pilihan item yang dikembalikan sheet opsi produk.
class ProductSelection {
  const ProductSelection({required this.variant, required this.modifiers});

  final ProductVariant variant;
  final List<Modifier> modifiers;
}

/// Sheet pilihan saat kartu produk diketuk: varian Reguler/Jumbo
/// (dengan harga masing-masing), gula, es, topping (multi-pilih,
/// harga topping dari ToppingService — Boba +3K, Jelly +2K, Selasih
/// +1K sebagai seed; Owner bisa ubah di Kelola Topping).
/// Topping AKTIF saja yang tampil; sebelum ToppingService init,
/// dipakai seed (toppingOptions) supaya widget test tetap jalan.
/// Harga live = harga varian + delta topping.
/// Mengembalikan ProductSelection atau null bila batal.
///
/// [initial] (Batch C5, mode edit): pilihan baris keranjang yang
/// sedang diedit — varian, gula, es, dan topping terisi dari baris
/// itu. Topping dicocokkan BERDASARKAN NAMA ke topping aktif saat
/// ini (hargaDelta ikut topping aktif, bukan yang tersimpan);
/// topping yang sudah tidak aktif lagi TIDAK ikut (dihapus Owner).
/// Tombol konfirmasi jadi "Simpan" (bukan "Tambah") di mode ini.
Future<ProductSelection?> showProductOptionsSheet(
  BuildContext context,
  Product product, {
  ProductSelection? initial,
}) async {
  final initialModifiers = initial?.modifiers ?? const <Modifier>[];
  // Gula/es dicari berdasarkan kind (nama bisa berubah-ubah, kind
  // tetap: 'gula' / 'es').
  Modifier _pickKind(String kind, List<Modifier> defaults) {
    for (final m in initialModifiers) {
      if (m.kind == kind) return m;
    }
    return defaults.first;
  }

  var variant = initial?.variant ?? product.variants.first;
  var gula = _pickKind('gula', gulaOptions);
  var es = _pickKind('es', esOptions);
  final toppings = <Modifier>{};
  // Snapshot saat sheet dibuka (tidak me-rebuild bila Owner mengubah
  // topping di halaman lain selagi sheet terbuka).
  final toppingChoices = ToppingService.instance.activeModifiers;
  // Topping awal: cocokkan berdasarkan nama ke topping aktif.
  for (final m in initialModifiers) {
    if (m.kind != 'topping') continue;
    for (final t in toppingChoices) {
      if (t.name == m.name) toppings.add(t);
    }
  }

  final result = await showModalBottomSheet<ProductSelection>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        final unitPrice = variant.price +
            toppings.fold<int>(0, (s, m) => s + m.priceDelta);
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle 30x4 (FigCraft frame 10).
              Center(
                child: Container(
                  width: 30,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFC9D6CE),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                product.name,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                product.category,
                style: const TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 16),
              const Text(
                'Ukuran',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in product.variants)
                    ChoiceChip(
                      label: Text(
                        '${v.name} • ${formatRupiah(v.price)}',
                      ),
                      selected: variant.id == v.id,
                      onSelected: (_) => setSheetState(() => variant = v),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Gula',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final g in gulaOptions)
                    ChoiceChip(
                      label: Text(g.name),
                      selected: gula.name == g.name,
                      onSelected: (_) => setSheetState(() => gula = g),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Es',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in esOptions)
                    ChoiceChip(
                      label: Text(e.name),
                      selected: es.name == e.name,
                      onSelected: (_) => setSheetState(() => es = e),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Topping (boleh lebih dari satu)',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in toppingChoices)
                    FilterChip(
                      label: Text(
                        '${t.name} +${formatRupiah(t.priceDelta)}',
                      ),
                      selected: toppings.contains(t),
                      onSelected: (selected) => setSheetState(() {
                        if (selected) {
                          toppings.add(t);
                        } else {
                          toppings.remove(t);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              // Total live (FigCraft frame 10): label kiri, nominal
              // emerald kanan — sebelum tombol Tambah.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Total',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    formatRupiah(unitPrice),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: SukaTeaColors.emerald,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TapFeedback(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    ProductSelection(
                      variant: variant,
                      modifiers: [gula, es, ...toppings],
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  child: Text(
                    initial != null
                        ? 'Simpan • ${formatRupiah(unitPrice)}'
                        : 'Tambah • ${formatRupiah(unitPrice)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  return result;
}
