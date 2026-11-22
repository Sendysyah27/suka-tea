import 'recipe_logic.dart';

/// RESEP AWAL — 20 produk poster x 2 varian (Reguler 16oz / Jumbo 22oz),
/// 22 Nov 2026. Angka per cup, ditakar dari resep stand es teh biasa.
/// Reguler pakai Cup 16oz, Jumbo pakai Cup 22oz — JANGAN tertukar.
/// Satuan ikut seedStock: kg untuk Teh/Gula/Es batu/Susu bubuk/
/// Bubuk perasa, pcs untuk Cup/Sedotan/Yakult/Lemon.
/// Owner bisa ubah tiap resep di Kelola Menu → Resep (lokal dulu,
/// sinkron Supabase di M1).
Map<String, List<RecipeLine>> seedRecipes() {
  // Bahan dasar semua es teh: teh + gula + cup + es batu + sedotan.
  List<RecipeLine> base({required bool jumbo}) => [
        RecipeLine(stockName: 'Teh', qty: jumbo ? 0.015 : 0.010),
        RecipeLine(stockName: 'Gula', qty: jumbo ? 0.035 : 0.025),
        RecipeLine(
          stockName: jumbo ? 'Cup 22oz' : 'Cup 16oz',
          qty: 1,
        ),
        RecipeLine(stockName: 'Es batu', qty: jumbo ? 0.20 : 0.15),
        const RecipeLine(stockName: 'Sedotan', qty: 1),
      ];

  // Milktea & varian susu: + susu bubuk + bubuk perasa.
  List<RecipeLine> milktea({required bool jumbo}) => [
        ...base(jumbo: jumbo),
        RecipeLine(stockName: 'Susu bubuk', qty: jumbo ? 0.030 : 0.020),
        RecipeLine(stockName: 'Bubuk perasa', qty: jumbo ? 0.020 : 0.015),
      ];

  // Mixtea biasa: base + bubuk perasa (rasa).
  List<RecipeLine> mixtea({required bool jumbo}) => [
        ...base(jumbo: jumbo),
        RecipeLine(stockName: 'Bubuk perasa', qty: jumbo ? 0.020 : 0.015),
      ];

  // Mixtea latte (Caffe Latte, Vanilla Latte): mixtea + susu bubuk.
  List<RecipeLine> mixteaLatte({required bool jumbo}) => [
        ...mixtea(jumbo: jumbo),
        RecipeLine(stockName: 'Susu bubuk', qty: jumbo ? 0.020 : 0.015),
      ];

  // Pasangan Reguler/Jumbo per produk: {'id': builder}.
  final builders = <String, List<RecipeLine> Function({required bool jumbo})>{
    // MILKTEA (5)
    'manggo-milktea': milktea,
    'coklat-milktea': milktea,
    'red-velvet-milktea': milktea,
    'taro-milktea': milktea,
    'thai-tea': milktea,
    // BEST SELLER
    'es-teh-jumbo': base,
    'es-teh-susu': ({required bool jumbo}) => [
          ...base(jumbo: jumbo),
          RecipeLine(stockName: 'Susu bubuk', qty: jumbo ? 0.030 : 0.020),
        ],
    'es-teh-lemon': ({required bool jumbo}) => [
          ...base(jumbo: jumbo),
          const RecipeLine(stockName: 'Lemon', qty: 1),
        ],
    'es-teh-yakult': ({required bool jumbo}) => [
          ...base(jumbo: jumbo),
          const RecipeLine(stockName: 'Yakult', qty: 1),
        ],
    'es-teh-apel': ({required bool jumbo}) => [
          ...base(jumbo: jumbo),
          RecipeLine(stockName: 'Bubuk perasa', qty: jumbo ? 0.020 : 0.015),
        ],
    // MIXTEA (10)
    'es-teh-coklat': mixtea,
    'es-teh-alpukat': mixtea,
    'es-teh-caffe-latte': mixteaLatte,
    'es-teh-taro': mixtea,
    'es-teh-leci': mixtea,
    'es-teh-vanilla-latte': mixteaLatte,
    'es-teh-durian': mixtea,
    'es-teh-strawberry': mixtea,
    'es-teh-permen-karet': mixtea,
    'es-teh-green-tea': mixtea,
  };

  final out = <String, List<RecipeLine>>{};
  for (final entry in builders.entries) {
    out['${entry.key}_r'] = entry.value(jumbo: false);
    out['${entry.key}_j'] = entry.value(jumbo: true);
  }
  return out;
}
