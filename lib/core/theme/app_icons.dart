/// Jalur aset ikon SVG (style Gen Z: garis tebal, membulat/playful).
/// Semua ikon berupa codingan SVG di assets/icons/ — TANPA emoji sebagai
/// ikon UI. Dipakai via flutter_svg (SvgPicture.asset).
class AppIcons {
  AppIcons._();

  static const String kasir = 'assets/icons/kasir.svg';
  static const String menu = 'assets/icons/menu.svg';
  static const String stok = 'assets/icons/stok.svg';
  static const String keuangan = 'assets/icons/keuangan.svg';
  static const String laporan = 'assets/icons/laporan.svg';
  static const String pengaturan = 'assets/icons/pengaturan.svg';
  static const String tambah = 'assets/icons/tambah.svg';
  static const String cari = 'assets/icons/cari.svg';
  static const String keranjang = 'assets/icons/keranjang.svg';
  static const String bayar = 'assets/icons/bayar.svg';
  static const String tutupKasir = 'assets/icons/tutup-kasir.svg';

  /// Ikon navbar 2026 (Lucide, ISC) — port dari FigCraft v26:
  /// receipt-text / shopping-bag / package / wallet / chart-column.
  /// Stroke SVG sudah dinormalisasi ke #000000 (currentColor diganti)
  /// supaya flutter_svg stabil; warna akhir dari ColorFilter srcIn.
  static const String navKasir = 'assets/icons/nav/receipt-text.svg';
  static const String navMenu = 'assets/icons/nav/shopping-bag.svg';
  static const String navStok = 'assets/icons/nav/package.svg';
  static const String navKeuangan = 'assets/icons/nav/wallet.svg';
  static const String navLaporan = 'assets/icons/nav/chart-column.svg';

  /// Ikon cara bayar (Lucide, ISC) — tile mint di payment sheet
  /// (FigCraft frame 02): banknote / landmark / qr-code / keyboard /
  /// wallet / split (Batch C2: QRIS + Tunai).
  static const String payTunai = 'assets/icons/pay/banknote.svg';
  static const String payTransfer = 'assets/icons/pay/landmark.svg';
  static const String payQris = 'assets/icons/pay/qr-code.svg';
  static const String payQrisManual = 'assets/icons/pay/keyboard.svg';
  static const String payEwallet = 'assets/icons/pay/wallet.svg';
  static const String paySplit = 'assets/icons/pay/split.svg';

  static const List<String> all = [
    kasir, menu, stok, keuangan, laporan, pengaturan,
    tambah, cari, keranjang, bayar, tutupKasir,
  ];
}
