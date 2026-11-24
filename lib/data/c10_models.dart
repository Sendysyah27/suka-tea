import 'models.dart';
import 'recipe_logic.dart';
import 'sale_history.dart';
import 'seed_menu.dart';

/// Model + fungsi MURNI Batch C10 (tanpa Flutter/Drift/Supabase —
/// bisa di-unit-test). Dipakai PackageService, BrewService,
/// Dashboard Owner, ledger, dan tab Stok kasir.
///
/// KONVENSI NAMA BAHAN (Batch C10 WS4):
/// - 'Teh Kering' = daun teh kering (kg) — awet, dibawa antar hari.
/// - 'Teh Masak' = teh yang sudah dimasak (liter) — hangus tiap
///   ganti hari, dipakai resep tiap cup (0,4 L/cup, default).
/// Nama lama 'Teh' (sebelum C10) = 'Teh Kering' (diganti migrasi
/// Drift v11 + migrasi Supabase 011; mutasi server lama yang masih
/// bernama 'Teh' dipetakan ke 'Teh Kering' di ledger).

/// Pseudo-outlet gudang pusat (Batch C10 §3): stok gudang = baris
/// StockLevels dengan outletId ini. TIDAK PERNAH di-seed, tidak
/// pernah tampil di picker gerai / Pantau Gerai / laporan per-gerai.
const String gudangOutletId = '00000000-0000-0000-0000-000000000000';

const String tehKeringName = 'Teh Kering';
const String tehMasakName = 'Teh Masak';

/// Takaran default Teh Masak per cup (liter) — Owner bisa ubah di
/// editor resep (Batch C10 WS4). BUKAN rasio masak: aksi Masak Teh
/// memakai angka kg + liter nyata dari yang masak.
const double defaultTehMasakPerCup = 0.4;

/// Masa simpan Teh Masak dalam hari (Batch C10 WS4).
const int tehMasakShelfLifeDays = 1;

/// Satuan baku yang boleh dipilih saat buat bahan baru (Batch C10
/// WS1 — satuan bahan TERKUNCI di semua form sesudahnya).
const List<String> stockUnits = ['kg', 'g', 'L', 'ml', 'pcs', 'porsi'];

/// Format jumlah: 120 -> "120", 2.5 -> "2,5" (koma Indonesia).
/// Dipakai semua halaman C10 supaya angka konsisten.
String formatQty(double v) {
  if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(3);
  s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  return s.replaceAll('.', ',');
}

/// Nama bahan lama 'Teh' (mutasi server sebelum C10) = 'Teh Kering'.
String normalizeStockName(String name) =>
    name == 'Teh' ? tehKeringName : name;

// ===================== Paket kiriman (WS2) =====================

/// Satu paket kiriman stok (Batch C10 WS2).
class StockPackage {
  const StockPackage({
    required this.id,
    required this.name,
    this.note = '',
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
    this.items = const [],
  });

  /// id = client_uuid (UUID v4) — kunci idempotency sync master-data.
  final String id;
  final String name;
  final String note;

  /// false = dihapus Owner (nonaktif + is_deleted di server —
  /// baris TIDAK pernah dihapus fisik dari history).
  final bool isActive;
  final DateTime createdAt;

  /// UTC — last-write-wins sync master-data.
  final DateTime updatedAt;
  final List<PackageItem> items;

  StockPackage copyWith({
    String? name,
    String? note,
    bool? isActive,
    DateTime? updatedAt,
    List<PackageItem>? items,
  }) =>
      StockPackage(
        id: id,
        name: name ?? this.name,
        note: note ?? this.note,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        items: items ?? this.items,
      );

  Map<String, dynamic> toMasterData() => {
        'name': name,
        'note': note,
        'is_active': isActive,
      };
}

/// Satu baris isi paket (Batch C10 WS2).
class PackageItem {
  const PackageItem({
    required this.id,
    required this.packageId,
    required this.stockName,
    required this.qty,
    required this.unit,
    required this.updatedAt,
  });

  /// id = client_uuid (UUID v4).
  final String id;
  final String packageId;
  final String stockName;

  /// Jumlah > 0 dalam [unit] = satuan baku bahan itu.
  final double qty;
  final String unit;

  /// UTC — last-write-wins sync master-data.
  final DateTime updatedAt;

  PackageItem copyWith({double? qty, String? unit}) => PackageItem(
        id: id,
        packageId: packageId,
        stockName: stockName,
        qty: qty ?? this.qty,
        unit: unit ?? this.unit,
        updatedAt: updatedAt,
      );

  Map<String, dynamic> toMasterData() => {
        'package_id': packageId,
        'stock_name': stockName,
        'qty': qty,
        'unit': unit,
      };
}

/// Nama paket tidak boleh sama (case-insensitive) di antara paket
/// aktif — dipakai validasi form Buat/Ubah Paket (Batch C10 WS2).
bool isPackageNameTaken(
  List<StockPackage> packages,
  String name, {
  String? excludeId,
}) {
  final clean = name.trim().toLowerCase();
  if (clean.isEmpty) return true;
  return packages.any(
    (p) =>
        p.isActive &&
        p.id != excludeId &&
        p.name.trim().toLowerCase() == clean,
  );
}

/// Template bawaan "Paket Standar Harian" (Batch C10 WS2): SEMUA
/// bahan seed, jumlah KOSONG (0) — Owner mengisi sekali.
/// Dibuat otomatis saat pertama install C10, HANYA bila belum ada
/// paket sama sekali. JANGAN karang angka.
StockPackage defaultPackageTemplate({required String id}) {
  final now = DateTime.now().toUtc();
  return StockPackage(
    id: id,
    name: 'Paket Standar Harian',
    note: 'Paket bawaan — isi jumlah tiap bahan sekali, lalu kirim '
        'tiap hari dari paket ini.',
    createdAt: now,
    updatedAt: now,
    items: [
      for (final s in seedStock())
        PackageItem(
          id: '$id|${s.name}',
          packageId: id,
          stockName: s.name,
          qty: 0,
          unit: s.unit,
          updatedAt: now,
        ),
    ],
  );
}

// ===================== Kiriman stok (WS3) =====================

/// Satu baris isi kiriman (Batch C10 WS3).
class SendItem {
  const SendItem({
    required this.stockName,
    required this.qty,
    required this.unit,
  });

  final String stockName;
  final double qty;
  final String unit;

  Map<String, dynamic> toJson() => {
        'name': stockName,
        'qty': qty,
        'unit': unit,
      };

  factory SendItem.fromJson(Map<String, dynamic> json) => SendItem(
        stockName: json['name'] as String? ?? '',
        qty: (json['qty'] as num? ?? 0).toDouble(),
        unit: json['unit'] as String? ?? 'pcs',
      );
}

/// Satu kiriman stok ke gerai (Batch C10 WS3).
class StockSend {
  const StockSend({
    required this.id,
    required this.outletId,
    this.packageId,
    this.packageName = '',
    required this.sentAt,
    this.sentBy = 'Owner',
    this.note = '',
    this.status = 'ok',
    this.items = const [],
  });

  /// id = client_uuid (UUID v4) — kunci idempotency sync.
  final String id;
  final String outletId;

  /// null = kirim custom / top-up tanpa paket.
  final String? packageId;

  /// Snapshot nama paket saat kirim.
  final String packageName;
  final DateTime sentAt;
  final String sentBy;
  final String note;

  /// 'ok' | 'gagal' (server menolak — gudang kurang — lalu kiriman
  /// dibalik lokal; baris TETAP tersimpan sebagai jejak gagal).
  final String status;
  final List<SendItem> items;

  StockSend copyWith({String? status}) => StockSend(
        id: id,
        outletId: outletId,
        packageId: packageId,
        packageName: packageName,
        sentAt: sentAt,
        sentBy: sentBy,
        note: note,
        status: status ?? this.status,
        items: items,
      );
}

/// Bahan yang kurang di gudang untuk satu kiriman (Batch C10 WS3).
class GudangShortage {
  const GudangShortage({
    required this.stockName,
    required this.unit,
    required this.needed,
    required this.available,
  });

  final String stockName;
  final String unit;
  final double needed;
  final double available;

  /// Selisih yang kurang (selalu > 0).
  double get missing => needed - available;
}

/// Cek gudang sebelum kirim (Batch C10 WS3, MURNI): tiap item
/// kiriman harus tersedia di gudang (qty gudang >= qty kirim).
/// Bahan yang tidak ada di gudang = tersedia 0 (kurang penuh).
/// Kosong = gudang cukup untuk semua item.
List<GudangShortage> checkGudang(
  List<SendItem> items,
  Map<String, StockItem> gudangByName,
) {
  final out = <GudangShortage>[];
  for (final item in items) {
    final have = gudangByName[item.stockName]?.qty ?? 0;
    if (item.qty > have) {
      out.add(GudangShortage(
        stockName: item.stockName,
        unit: item.unit,
        needed: item.qty,
        available: have,
      ));
    }
  }
  return out;
}

// ===================== Stok masuk (WS1) =====================

/// Satu pencatatan stok masuk gudang (Batch C10 WS1).
class StockInRecord {
  const StockInRecord({
    required this.id,
    required this.stockName,
    required this.unit,
    required this.qty,
    this.totalPrice = 0,
    this.supplier = '',
    required this.date,
    this.note = '',
    required this.createdAt,
    this.pending = false,
  });

  /// id = client_uuid (UUID v4).
  final String id;
  final String stockName;
  final String unit;
  final double qty;

  /// Harga beli TOTAL (Rp). 0 = tidak diisi — costPerUnit bahan
  /// TIDAK berubah bila 0; bila > 0, costPerUnit baru = total / qty.
  final int totalPrice;
  final String supplier;

  /// Tanggal masuk (default hari ini, maks 30 hari mundur, tidak
  /// pernah masa depan).
  final DateTime date;
  final String note;
  final DateTime createdAt;

  /// true = masih antre di outbox (belum terkirim ke server).
  final bool pending;
}

// ===================== Masak teh (WS4) =====================

/// Satu aksi Masak Teh (Batch C10 WS4).
class BrewRecord {
  const BrewRecord({
    required this.id,
    required this.outletId,
    required this.kgUsed,
    required this.litersMade,
    required this.brewedAt,
    this.brewedBy = 'Owner',
    this.expiredLiters = 0,
    required this.updatedAt,
  });

  /// id = client_uuid (UUID v4).
  final String id;
  final String outletId;

  /// Teh Kering dipakai (kg) — angka nyata dari yang masak.
  final double kgUsed;

  /// Teh Masak dihasilkan (liter) — angka nyata, BUKAN rasio.
  final double litersMade;
  final DateTime brewedAt;
  final String brewedBy;

  /// Sisa Teh Masak kemarin yang hangus saat masak ini (liter).
  /// 0 = masak di hari yang sama / tidak ada sisa kemarin.
  final double expiredLiters;

  /// UTC — last-write-wins sync.
  final DateTime updatedAt;
}

/// Status masak per gerai (Batch C10 WS4): tanggal TERAKHIR Teh
/// Masak dimasak + total liter hari itu. Model MURNI (in-memory) —
/// baris Drift-nya `BrewStates` (class `DbBrewState`).
class BrewState {
  const BrewState({
    required this.outletId,
    required this.brewedDate,
    this.litersMade = 0,
  });

  final String outletId;

  /// Tanggal terakhir masak (tanpa jam).
  final DateTime brewedDate;

  /// Total liter Teh Masak yang dimasak hari itu.
  final double litersMade;
}

/// true = Teh Masak di gerai ini sudah lewat hari ([brewedDate]
/// = tanggal terakhir masak; null = belum pernah masak).
/// Sisa kemarin hangus (kedaluwarsa) bila true (Batch C10 WS4).
bool isBrewExpired(DateTime? brewedDate, DateTime now) {
  if (brewedDate == null) return false;
  final brewedDay = DateTime(brewedDate.year, brewedDate.month, brewedDate.day);
  final today = DateTime(now.year, now.month, now.day);
  return brewedDay.isBefore(today);
}

/// Sisa Teh Masak yang hangus = seluruh saldo saat ini (bila sudah
/// lewat hari). 0 bila belum lewat hari / saldo sudah 0.
double expiredTehMasakLiters({
  required DateTime? brewedDate,
  required double currentLiters,
  required DateTime now,
}) =>
    isBrewExpired(brewedDate, now) ? currentLiters : 0;

// ===================== Opname (WS6) =====================

/// Satu baris opname: satu bahan yang dihitung (Batch C10 WS6).
class StockOpname {
  const StockOpname({
    required this.id,
    required this.outletId,
    required this.stockName,
    required this.systemQty,
    required this.physicalQty,
    required this.countedAt,
    this.countedBy = 'Owner',
    this.note = '',
    this.adjusted = false,
    required this.updatedAt,
  });

  /// id = client_uuid (UUID v4) — satu baris = satu bahan.
  final String id;
  final String outletId;
  final String stockName;

  /// Snapshot stok sistem saat hitung (read-only di UI).
  final double systemQty;

  /// Hasil hitung fisik (input Owner, >= 0).
  final double physicalQty;
  final DateTime countedAt;
  final String countedBy;
  final String note;

  /// true = Owner sudah menekan "Sesuaikan stok" untuk baris ini
  /// (stok sistem diubah sebesar selisih).
  final bool adjusted;

  /// UTC — last-write-wins sync.
  final DateTime updatedAt;

  /// Selisih = fisik − sistem (negatif = kurang / susut).
  double get difference => physicalQty - systemQty;

  /// Perkiraan nilai selisih (Rp) dari [costPerUnit] bahan itu —
  /// label UI wajib "perkiraan" (Batch C10 WS6).
  int differenceRupiah(double costPerUnit) =>
      (difference * (costPerUnit < 0 ? 0 : costPerUnit)).round();

  StockOpname copyWith({bool? adjusted, DateTime? updatedAt}) =>
      StockOpname(
        id: id,
        outletId: outletId,
        stockName: stockName,
        systemQty: systemQty,
        physicalQty: physicalQty,
        countedAt: countedAt,
        countedBy: countedBy,
        note: note,
        adjusted: adjusted ?? this.adjusted,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

// ===================== Target omzet (WS7 §4) =====================

/// Target omzet harian satu gerai (Batch C10 WS7 §4).
class GeraiTarget {
  const GeraiTarget({
    required this.outletId,
    required this.targetOmzet,
    required this.updatedAt,
  });

  final String outletId;

  /// Rupiah per hari. 0 = belum ada target.
  final int targetOmzet;

  /// UTC — last-write-wins sync master-data.
  final DateTime updatedAt;
}

// ===================== Tab Stok kasir (WS5) =====================

/// "Bisa jual N cup" untuk satu produk (Batch C10 WS5, MURNI):
/// N = minimum atas semua baris resep (floor(stok gerai / takaran
/// per cup)); bahan yang tidak ada di stok gerai = 0; Teh Masak
/// ikut dihitung (resep memakai Teh Masak).
/// [limitingStock] = bahan pembatas (yang menentukan N) — dipakai
/// label "habis karena X" (Teh Masak habis -> tombol Masak Teh).
/// Topping TIDAK dihitung (topping opsional — tidak menentukan
/// bisa/tidaknya satu menu dijual).
({int cups, String? limitingStock}) sellableCupsForProduct(
  List<RecipeLine> recipe,
  Map<String, StockItem> stockByName,
) {
  if (recipe.isEmpty) return (cups: 0, limitingStock: null);
  var min = 1 << 30;
  String? limiting;
  for (final line in recipe) {
    final stock = stockByName[line.stockName];
    if (stock == null || line.qty <= 0) {
      return (cups: 0, limitingStock: line.stockName);
    }
    // Epsilon lawan galat floating-point: 0,35/0,035 = 9,999... di
    // biner (floor jadi 9 padahal 10) — takaran resep desimal rentan
    // ini (ditemukan unit test C10). Epsilon 1e-9 tidak mengubah
    // hasil bila stok memang kurang 0,001 dari kelipatan.
    final n = (stock.qty / line.qty + 1e-9).floor();
    if (n < min) {
      min = n;
      limiting = line.stockName;
    }
  }
  return (cups: min, limitingStock: min == 0 ? limiting : null);
}

/// Nama bahan yang membatasi satu resep (paling cepat habis), tanpa
/// memandang apakah kapasitasnya 0 atau tidak. Dipakai label
/// "Paling tipis" §6/Tab Stok (Batch C10.2 W3).
String? _limitingStockName(
  List<RecipeLine> recipe,
  Map<String, StockItem> stockByName,
) {
  if (recipe.isEmpty) return null;
  var min = 1 << 30;
  String? limiting;
  for (final line in recipe) {
    final stock = stockByName[line.stockName];
    final n = (stock == null || line.qty <= 0)
        ? 0
        : (stock.qty / line.qty + 1e-9).floor();
    if (n < min) {
      min = n;
      limiting = line.stockName;
    }
  }
  return limiting;
}

/// Kapasitas gerai yang JUJUR (Batch C10.2 W3): MAKSIMUM cup SATU
/// menu — bukan jumlah kapasitas semua menu.
///
/// Alasan: semua menu memakai bahan bersama (Teh Masak, Gula, Cup),
/// jadi menjual 20 cup menu apa pun dari 8 L Teh Masak adalah batas
/// nyata; mencampur menu tidak bisa melampaui menu tunggal terbaik
/// (ada menu polos yang hanya memakai bahan bersama). Menjumlahkan
/// kapasitas per menu (perilaku C10) menghasilkan 400 cup untuk
/// stok yang sama — angka itu menyesatkan (bug B3).
///
/// [limitingStock] = bahan yang membatasi menu dengan kapasitas
/// maksimum (menu pertama bila semua 0) — dipakai label "Paling
/// tipis". Tipe kembalian [totalCapacityCups] tetap `int` supaya
/// pemanggil lama tidak berubah.
({int cups, String? limitingStock}) capacityForOutlet(
  List<Product> products,
  Map<String, List<RecipeLine>> recipes,
  Map<String, StockItem> stockByName,
) {
  var best = 0;
  String? limiting;
  Product? firstActive;
  for (final p in products) {
    if (!p.isActive) continue;
    firstActive ??= p;
    final recipe = recipes[p.variants.first.id] ?? const <RecipeLine>[];
    final cups = sellableCupsForProduct(recipe, stockByName).cups;
    if (cups > best) {
      best = cups;
      limiting = _limitingStockName(recipe, stockByName);
    }
  }
  if (best == 0) {
    final recipe = firstActive == null
        ? const <RecipeLine>[]
        : (recipes[firstActive.variants.first.id] ?? const <RecipeLine>[]);
    limiting = _limitingStockName(recipe, stockByName);
  }
  return (cups: best, limitingStock: limiting);
}

/// Total kapasitas gerai (Batch C10.2 W3) — lihat [capacityForOutlet]:
/// MAKSIMUM cup satu menu (bukan penjumlahan per menu).
int totalCapacityCups(
  List<Product> products,
  Map<String, List<RecipeLine>> recipes,
  Map<String, StockItem> stockByName,
) =>
    capacityForOutlet(products, recipes, stockByName).cups;

/// Bahan pembatas kapasitas serentak (Batch C10.2 W3) — untuk label
/// "Paling tipis" bila pemanggil butuh nama bahannya.
String? limitingStockForCapacity(
  List<Product> products,
  Map<String, List<RecipeLine>> recipes,
  Map<String, StockItem> stockByName,
) =>
    capacityForOutlet(products, recipes, stockByName).limitingStock;

// ===================== Ledger keluar-masuk (WS8) =====================

/// Jenis baris ledger (Batch C10 WS8). MASUK/KELUAR/TERBUANG/OPNAME
/// dari brief; MASAK + KOREKSI ditambahkan karena keduanya mengubah
/// stok sistem tapi bukan penjualan/buang/opname — tanpa keduanya
/// rekonsiliasi tidak bisa menutup (lihat buildLedger).
enum LedgerKind { masuk, keluar, terbuang, opname, masak, koreksi }

extension LedgerKindX on LedgerKind {
  String get label => switch (this) {
        LedgerKind.masuk => 'MASUK',
        LedgerKind.keluar => 'KELUAR',
        LedgerKind.terbuang => 'TERBUANG',
        LedgerKind.opname => 'OPNAME',
        LedgerKind.masak => 'MASAK',
        LedgerKind.koreksi => 'KOREKSI',
      };
}

/// Satu baris ledger keluar-masuk barang per gerai (Batch C10 WS8).
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.at,
    required this.kind,
    required this.stockName,
    required this.qty,
    required this.unit,
    required this.reference,
    required this.by,
  });

  /// Kunci dedupe (mis. 'send:<id>|<bahan>', 'mov:<clientUuid>|<bahan>').
  final String id;
  final DateTime at;
  final LedgerKind kind;
  final String stockName;

  /// Delta bertanda: + = masuk, − = keluar/terbuang.
  final double qty;
  final String unit;

  /// Referensi asal (id kiriman / id transaksi / id opname /
  /// 'Masak Teh' / 'Koreksi stok') — ketuk = buka detail asal
  /// (bila ada halamannya; bila tidak, tampilkan id-nya).
  final String reference;

  /// Siapa (Owner / nama kasir / nama penghitung opname).
  final String by;
}

/// Satu mutasi stok mentah (bentuk ringkas dari SyncService —
/// dipakai buildLedger supaya tidak import SyncService ke model
/// murni). [reason] = reason server ('penjualan', 'void',
/// 'koreksi', 'tambah', 'kedaluwarsa', 'opname', 'brew', 'kirim').
typedef LedgerMovement = ({
  String clientUuid,
  String name,
  double qtyDelta,
  String reason,
  DateTime createdAt,
});

/// Ringkasan per bahan (Batch C10 WS8): masuk, keluar, terbuang,
/// selisih opname, masak (masuk Teh Masak / keluar Teh Kering),
/// koreksi, dan SISA yang HARUS sama dengan stok sistem.
/// [openingQty] = saldo awal (seed — bahan baru = 0).
class LedgerSummaryItem {
  const LedgerSummaryItem({
    required this.stockName,
    required this.unit,
    required this.openingQty,
    required this.masuk,
    required this.keluar,
    required this.terbuang,
    required this.opname,
    required this.masak,
    required this.koreksi,
    required this.systemQty,
  });

  final String stockName;
  final String unit;
  final double openingQty;

  /// Jumlah masuk (positif) dari kiriman.
  final double masuk;

  /// Jumlah keluar (positif) dari penjualan (net void).
  final double keluar;

  /// Jumlah terbuang (positif) — Teh Masak kedaluwarsa.
  final double terbuang;

  /// Selisih opname yang SUDAH disesuaikan (bertanda: + = fisik
  /// lebih, − = fisik kurang). Opname yang belum disesuaikan
  /// TIDAK masuk angka ini (tidak mengubah stok sistem).
  final double opname;

  /// Net masak (bertanda): Teh Masak +liter, Teh Kering −kg.
  final double masak;

  /// Net koreksi manual + bahan baru (bertanda).
  final double koreksi;
  final double systemQty;

  /// Sisa menurut pembukuan = saldo awal + semua mutasi.
  double get expectedQty =>
      openingQty + masuk - keluar - terbuang + opname + masak + koreksi;

  /// Selisih pembukuan = sistem − pembukuan. 0 = menutup.
  double get gap => systemQty - expectedQty;

  bool get matches => gap.abs() < 0.001;
}

/// Hasil build ledger: baris + ringkasan per bahan.
typedef LedgerResult = ({
  List<LedgerEntry> entries,
  List<LedgerSummaryItem> summary,
});

/// Bangun ledger keluar-masuk + ringkasan per bahan (Batch C10 WS8,
/// MURNI). Sumber (semua sudah digabung antar device oleh C9/C10):
/// - MASUK: [sends] (kiriman ke gerai itu, semua waktu).
/// - KELUAR: [movements] reason 'penjualan' (delta negatif) +
///   'void' (delta positif = pengembalian) — mutasi mencatat
///   deduksi NYATA saat penjualan (termasuk resep lama 'Teh'),
///   jadi ledger tidak menebak dari resep saat ini.
/// - TERBUANG: [movements] reason 'kedaluwarsa'.
/// - OPNAME: [opnames] yang adjusted=true saja.
/// - MASAK: [brews] (Teh Kering −kg, Teh Masak +liter).
/// - KOREKSI: [movements] reason 'koreksi' + 'tambah'.
/// DIABAIKAN (sudah terwakili sumber lain): reason 'kirim' (=
/// kiriman, sudah di MASUK), 'brew' (= masak, sudah di MASAK),
/// 'opname' (= baris opname, sudah di OPNAME).
/// [openingQty] per bahan = saldo awal (seed — bahan baru = 0).
/// [systemQty] per bahan = stok sistem gerai itu saat ini.
/// CATATAN JUJUR: ringkasan hanya menutup bila SEMUA riwayat ada di
/// HP ini. HP baru hanya punya 30 hari pull + data lokal — mutasi
/// lama dari HP lain (termasuk yang hilang karena bug 23505
/// sebelum C9) tidak ada di sini, jadi gap bisa muncul; gap itu
/// DITAMPILKAN (banner merah), bukan disembunyikan.
LedgerResult buildLedger({
  required String outletId,
  required List<StockSend> sends,
  required List<LedgerMovement> movements,
  required List<StockOpname> opnames,
  required List<BrewRecord> brews,
  required Map<String, double> openingQty,
  required Map<String, StockItem> systemStock,
}) {
  final entries = <LedgerEntry>[];
  final masuk = <String, double>{};
  final keluar = <String, double>{};
  final terbuang = <String, double>{};
  final opnameDelta = <String, double>{};
  final masak = <String, double>{};
  final koreksi = <String, double>{};

  void add(Map<String, double> map, String name, double v) {
    map[name] = (map[name] ?? 0) + v;
  }

  for (final send in sends) {
    if (send.outletId != outletId) continue;
    if (send.status != 'ok') continue;
    for (final item in send.items) {
      final name = normalizeStockName(item.stockName);
      add(masuk, name, item.qty);
      entries.add(LedgerEntry(
        id: 'send:${send.id}|$name',
        at: send.sentAt,
        kind: LedgerKind.masuk,
        stockName: name,
        qty: item.qty,
        unit: item.unit,
        reference: send.packageName.isEmpty
            ? 'Kiriman ${send.id.substring(0, 8)}'
            : 'Kiriman: ${send.packageName}',
        by: send.sentBy,
      ));
    }
  }

  for (final m in movements) {
    final name = normalizeStockName(m.name);
    final unit = systemStock[name]?.unit ?? 'pcs';
    switch (m.reason) {
      case 'penjualan':
        add(keluar, name, -m.qtyDelta);
        entries.add(LedgerEntry(
          id: 'mov:${m.clientUuid}|$name',
          at: m.createdAt,
          kind: LedgerKind.keluar,
          stockName: name,
          qty: m.qtyDelta,
          unit: unit,
          reference: 'Penjualan',
          by: '',
        ));
      case 'void':
        // Pengembalian stok (delta positif) mengurangi KELUAR net.
        add(keluar, name, -m.qtyDelta);
        entries.add(LedgerEntry(
          id: 'mov:${m.clientUuid}|$name',
          at: m.createdAt,
          kind: LedgerKind.keluar,
          stockName: name,
          qty: m.qtyDelta,
          unit: unit,
          reference: 'Void (stok kembali)',
          by: '',
        ));
      case 'kedaluwarsa':
        add(terbuang, name, -m.qtyDelta);
        entries.add(LedgerEntry(
          id: 'mov:${m.clientUuid}|$name',
          at: m.createdAt,
          kind: LedgerKind.terbuang,
          stockName: name,
          qty: m.qtyDelta,
          unit: unit,
          reference: 'Teh Masak kedaluwarsa',
          by: '',
        ));
      case 'koreksi':
      case 'tambah':
        add(koreksi, name, m.qtyDelta);
        entries.add(LedgerEntry(
          id: 'mov:${m.clientUuid}|$name',
          at: m.createdAt,
          kind: LedgerKind.koreksi,
          stockName: name,
          qty: m.qtyDelta,
          unit: unit,
          reference: m.reason == 'tambah'
              ? 'Bahan baru'
              : 'Koreksi stok',
          by: '',
        ));
      default:
        // 'kirim' / 'brew' / 'opname' = sudah terwakili sumber lain.
        continue;
    }
  }

  for (final o in opnames) {
    if (o.outletId != outletId) continue;
    if (!o.adjusted) continue;
    final name = normalizeStockName(o.stockName);
    add(opnameDelta, name, o.difference);
    entries.add(LedgerEntry(
      id: 'opname:${o.id}',
      at: o.countedAt,
      kind: LedgerKind.opname,
      stockName: name,
      qty: o.difference,
      unit: systemStock[name]?.unit ?? 'pcs',
      reference: 'Opname ${o.id.substring(0, 8)}',
      by: o.countedBy,
    ));
  }

  for (final b in brews) {
    if (b.outletId != outletId) continue;
    add(masak, tehKeringName, -b.kgUsed);
    add(masak, tehMasakName, b.litersMade);
    entries.add(LedgerEntry(
      id: 'brew:${b.id}|$tehKeringName',
      at: b.brewedAt,
      kind: LedgerKind.masak,
      stockName: tehKeringName,
      qty: -b.kgUsed,
      unit: 'kg',
      reference: 'Masak Teh',
      by: b.brewedBy,
    ));
    entries.add(LedgerEntry(
      id: 'brew:${b.id}|$tehMasakName',
      at: b.brewedAt,
      kind: LedgerKind.masak,
      stockName: tehMasakName,
      qty: b.litersMade,
      unit: 'liter',
      reference: 'Masak Teh',
      by: b.brewedBy,
    ));
  }

  entries.sort((a, b) => b.at.compareTo(a.at));

  final names = <String>{
    ...openingQty.keys,
    ...masuk.keys,
    ...keluar.keys,
    ...terbuang.keys,
    ...opnameDelta.keys,
    ...masak.keys,
    ...koreksi.keys,
    ...systemStock.keys,
  };
  final summary = <LedgerSummaryItem>[];
  for (final name in names) {
    summary.add(LedgerSummaryItem(
      stockName: name,
      unit: systemStock[name]?.unit ?? 'pcs',
      openingQty: openingQty[name] ?? 0,
      masuk: masuk[name] ?? 0,
      keluar: keluar[name] ?? 0,
      terbuang: terbuang[name] ?? 0,
      opname: opnameDelta[name] ?? 0,
      masak: masak[name] ?? 0,
      koreksi: koreksi[name] ?? 0,
      systemQty: systemStock[name]?.qty ?? 0,
    ));
  }
  summary.sort((a, b) => a.stockName.compareTo(b.stockName));
  return (entries: entries, summary: summary);
}

/// Pemakaian bahan dari penjualan (untuk HPP per gerai di Dashboard
/// — dipakai bersama computeDailyStats yang sudah ada).
/// Dihitung dari resep SAAT INI x penjualan aktif (bukan dari
/// mutasi) — perkiraan yang sama dengan HPP Keuangan/Laporan.
Map<String, double> usageFromSales(
  List<SaleRecord> sales,
  Map<String, List<RecipeLine>> recipes,
  Set<String> toppingNames,
) {
  final out = <String, double>{};
  for (final s in sales) {
    if (s.isVoid) continue;
    for (final item in s.items) {
      for (final line in recipes[item.variantId] ?? const <RecipeLine>[]) {
        out[line.stockName] =
            (out[line.stockName] ?? 0) + line.qty * item.qty;
      }
      for (final name in item.modifiers) {
        if (!toppingNames.contains(name)) continue;
        out[name] = (out[name] ?? 0) + 1 * item.qty;
      }
    }
  }
  return out;
}
