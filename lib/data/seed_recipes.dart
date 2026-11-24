import 'recipe_logic.dart';

/// RESEP AWAL — 20 produk poster x 1 varian 22oz (Batch C8.2 WS7),
/// 22 Nov 2026. Angka per cup, ditakar dari resep stand es teh biasa.
/// Batch C8.2 WS7: tiap produk kini 1 resep — pakai takaran Jumbo
/// yang lama (cup 22oz pakai takaran Jumbo: Gula 0.035, Es batu 0.20,
/// Susu bubuk 0.030, Bubuk perasa 0.020). Resep Reguler (16oz)
/// DIHAPUS dari seed — baris resep `_r`/`_j` lama di DB install
/// yang sudah ada SENGAJA DIBIARKAN (tidak dihapus) supaya
/// void-restore penjualan lama tetap menemukan resepnya.
/// Satuan ikut seedStock: kg untuk Gula/Es batu/Susu bubuk/
/// Bubuk perasa, liter untuk Teh Masak, pcs untuk Cup/Sedotan/
/// Yakult/Lemon.
/// Batch C10 WS4: 'Teh' 0.015 kg DIGANTI 'Teh Masak' 0.4 liter per
/// cup (default — Owner bisa ubah di editor resep). Teh Kering
/// (daun, kg) TIDAK dipakai resep — dia dipakai saat MASAK teh,
/// lalu jadi Teh Masak. Baris resep _22oz lama yang masih memakai
/// 'Teh' diganti migrasi Drift v11 (bukan di seed ini).
/// Owner bisa ubah tiap resep di Kelola Menu → Resep (sinkron
/// Supabase di C10 WS0 — master-data).
Map<String, List<RecipeLine>> seedRecipes() {
  // Bahan dasar semua es teh: teh masak + gula + cup + es batu +
  // sedotan.
  List<RecipeLine> base() => [
        const RecipeLine(stockName: 'Teh Masak', qty: 0.4),
        const RecipeLine(stockName: 'Gula', qty: 0.035),
        const RecipeLine(stockName: 'Cup 22oz', qty: 1),
        const RecipeLine(stockName: 'Es batu', qty: 0.20),
        const RecipeLine(stockName: 'Sedotan', qty: 1),
      ];

  // Milktea & varian susu: + susu bubuk + bubuk perasa.
  List<RecipeLine> milktea() => [
        ...base(),
        const RecipeLine(stockName: 'Susu bubuk', qty: 0.030),
        const RecipeLine(stockName: 'Bubuk perasa', qty: 0.020),
      ];

  // Mixtea biasa: base + bubuk perasa (rasa).
  List<RecipeLine> mixtea() => [
        ...base(),
        const RecipeLine(stockName: 'Bubuk perasa', qty: 0.020),
      ];

  // Mixtea latte (Caffe Latte, Vanilla Latte): mixtea + susu bubuk.
  List<RecipeLine> mixteaLatte() => [
        ...mixtea(),
        const RecipeLine(stockName: 'Susu bubuk', qty: 0.020),
      ];

  // Builder resep per produk: {'id': builder}.
  final builders = <String, List<RecipeLine> Function()>{
    // MILKTEA (5)
    'manggo-milktea': milktea,
    'coklat-milktea': milktea,
    'red-velvet-milktea': milktea,
    'taro-milktea': milktea,
    'thai-tea': milktea,
    // BEST SELLER
    'es-teh-jumbo': base,
    'es-teh-susu': () => [
          ...base(),
          const RecipeLine(stockName: 'Susu bubuk', qty: 0.030),
        ],
    'es-teh-lemon': () => [
          ...base(),
          const RecipeLine(stockName: 'Lemon', qty: 1),
        ],
    'es-teh-yakult': () => [
          ...base(),
          const RecipeLine(stockName: 'Yakult', qty: 1),
        ],
    'es-teh-apel': () => [
          ...base(),
          const RecipeLine(stockName: 'Bubuk perasa', qty: 0.020),
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
    // Batch C8.2 WS7: SATU resep per produk — takaran Jumbo lama
    // (cup 22oz), kunci `{id}_22oz`.
    out['${entry.key}_22oz'] = entry.value();
  }
  return out;
}
