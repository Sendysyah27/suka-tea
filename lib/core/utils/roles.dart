/// Peran di satu outlet. Mode Owner di app HANYA terbuka lewat PIN Owner
/// (hash bcrypt di Supabase, verifikasi via Edge Function — lihat
/// features/pin). RLS di Supabase adalah penegak utamanya di server;
/// helper ini hanya untuk menyembunyikan/menampilkan menu di UI.
enum AppRole { owner, kasir }

extension AppRoleX on AppRole {
  /// Hanya Owner yang boleh baca laba/HPP, kelola menu, dan export Sheets.
  bool get canViewProfit => this == AppRole.owner;
  bool get canManageMenu => this == AppRole.owner;
  bool get canManageStock => this == AppRole.owner;
  bool get canExportSheets => this == AppRole.owner;
  bool get canCloseShift => this == AppRole.owner;

  /// Hanya Owner yang boleh kelola topping (Batch C1).
  bool get canManageToppings => this == AppRole.owner;

  /// Hanya Owner yang boleh void transaksi (Batch C1).
  bool get canVoidSale => this == AppRole.owner;

  /// Hanya Owner yang boleh kelola gerai: tambah/ubah/hapus gerai,
  /// pantau gerai, dan ubah PIN Kasir gerai (Batch C4).
  bool get canManageOutlets => this == AppRole.owner;
}
