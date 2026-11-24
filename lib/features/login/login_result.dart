import '../../core/utils/roles.dart';

/// Hasil login: gerai yang dipilih + peran sesi ini.
/// File sendiri supaya login_page.dart dan kasir_pin_page.dart
/// tidak saling import (keduanya memakai tipe ini).
///
/// Batch C8.2: login kasir membawa identitas dari SERVER
/// (verify-cashier-pin) — [cashierId] + [cashierName] terisi untuk
/// peran kasir (bukan ketikan kasir — kasir dilarang isi nama
/// sendiri). Owner = null (tanpa sesi kasir).
class LoginResult {
  const LoginResult({
    required this.outletId,
    required this.role,
    this.cashierId,
    this.cashierName,
  });

  final String outletId;
  final AppRole role;
  final String? cashierId;
  final String? cashierName;
}
