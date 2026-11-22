/// Peran di satu outlet. RLS di Supabase adalah penegak utamanya;
/// helper ini hanya untuk menyembunyikan/menampilkan menu di UI.
enum AppRole { owner, kasir }

extension AppRoleX on AppRole {
  /// Hanya Owner yang boleh baca laba/HPP, kelola menu, dan export Sheets.
  bool get canViewProfit => this == AppRole.owner;
  bool get canManageMenu => this == AppRole.owner;
  bool get canExportSheets => this == AppRole.owner;
  bool get canCloseShift => this == AppRole.owner;
}
