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

  static const List<String> all = [
    kasir, menu, stok, keuangan, laporan, pengaturan,
    tambah, cari, keranjang, bayar, tutupKasir,
  ];
}
