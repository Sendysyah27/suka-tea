import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';

/// Pilihan item yang dikembalikan sheet opsi produk.
class ProductSelection {
  const ProductSelection({required this.variant, required this.modifiers});

  final ProductVariant variant;
  final List<Modifier> modifiers;
}

/// Sheet pilihan saat kartu produk diketuk: varian Reguler/Jumbo
/// (dengan harga masing-masing), gula, es, topping (multi-pilih,
/// harga topping dari seed_menu — Boba +3K, Jelly +2K, Selasih +1K).
/// Harga live = harga varian + delta topping.
/// Mengembalikan ProductSelection atau null bila batal.
Future<ProductSelection?> showProductOptionsSheet(
  BuildContext context,
  Product product,
) async {
  var variant = product.variants.first;
  var gula = gulaOptions.first;
  var es = esOptions.first;
  final toppings = <Modifier>{};

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
                  for (final t in toppingOptions)
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
                    'Tambah • ${formatRupiah(unitPrice)}',
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
