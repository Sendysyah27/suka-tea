import '../../core/utils/roles.dart';

/// Hasil login: gerai yang dipilih + peran sesi ini.
/// File sendiri supaya login_page.dart dan kasir_pin_page.dart
/// tidak saling import (keduanya memakai tipe ini).
class LoginResult {
  const LoginResult({required this.outletId, required this.role});

  final String outletId;
  final AppRole role;
}
