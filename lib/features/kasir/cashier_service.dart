import 'package:flutter/foundation.dart';

import '../../data/outlet_service.dart';
import '../../data/supabase_client.dart';
import '../pin/pin_service.dart';

/// Satu kasir terdaftar (Batch C8.2 — registri kasir Owner).
class Cashier {
  const Cashier({
    required this.id,
    required this.name,
    this.active = true,
  });

  /// UUID Supabase (tabel `cashiers`).
  final String id;

  /// Nama yang didaftarkan Owner — identitas kasir di struk,
  /// riwayat, dan Pantau Gerai.
  final String name;

  /// false = dinonaktifkan Owner (PIN tidak bisa dipakai login).
  final bool active;

  factory Cashier.fromJson(Map<String, dynamic> json) => Cashier(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        active: json['active'] != false,
      );
}

/// Hasil verifikasi PIN kasir (Batch C8.2 — login kasir baru).
enum CashierVerifyResult { ok, wrong, locked, notFound, unavailable }

/// Hasil mentah Edge Function `list-cashiers` -> (ok, daftar kasir).
/// [ok] = false bila bukan peta / ok != true / cashiers bukan list.
/// Entri yang rusak (tanpa id/nama) dilewati, bukan gagal total.
({bool ok, List<Cashier> cashiers}) parseCashierListResponse(dynamic data) {
  if (data is! Map) return (ok: false, cashiers: const <Cashier>[]);
  if (data['ok'] != true) return (ok: false, cashiers: const <Cashier>[]);
  final raw = data['cashiers'];
  if (raw is! List) return (ok: false, cashiers: const <Cashier>[]);
  final list = <Cashier>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id'];
    final name = entry['name'];
    if (id is! String || id.isEmpty) continue;
    if (name is! String || name.isEmpty) continue;
    list.add(
      Cashier(
        id: id,
        name: name,
        active: entry['active'] != false,
      ),
    );
  }
  return (ok: true, cashiers: list);
}

/// Hasil mentah Edge Function `verify-cashier-pin` -> (result, id, nama).
/// ok:true + cashier_id + name terisi = ok; ok:false + reason =
/// 'wrong'/'locked'/'not_found' = hasil itu; selainnya = unavailable.
({
  CashierVerifyResult result,
  String? cashierId,
  String? name,
}) parseVerifyCashierResponse(dynamic data) {
  if (data is! Map) {
    return (result: CashierVerifyResult.unavailable, cashierId: null, name: null);
  }
  if (data['ok'] == true) {
    final id = data['cashier_id'];
    final name = data['name'];
    if (id is String && id.isNotEmpty && name is String && name.isNotEmpty) {
      return (result: CashierVerifyResult.ok, cashierId: id, name: name);
    }
    return (result: CashierVerifyResult.unavailable, cashierId: null, name: null);
  }
  switch (data['reason']) {
    case 'wrong':
      return (result: CashierVerifyResult.wrong, cashierId: null, name: null);
    case 'locked':
      return (result: CashierVerifyResult.locked, cashierId: null, name: null);
    case 'not_found':
      return (result: CashierVerifyResult.notFound, cashierId: null, name: null);
    default:
      return (result: CashierVerifyResult.unavailable, cashierId: null, name: null);
  }
}

/// Pesan error server dari jawaban EF kasir (mis. 'pin_taken',
/// 'name_taken', 'cashier_not_found') — null bila tidak ada / bukan
/// string. Dipakai halaman Kelola Kasir untuk pesan yang jelas.
String? parseCashierError(dynamic data) {
  if (data is! Map) return null;
  final error = data['error'];
  return error is String && error.isNotEmpty ? error : null;
}

/// Nama kasir yang sah untuk didaftarkan Owner: tidak kosong,
/// maks 50 karakter (batas yang sama dengan EF register-cashier).
bool isValidCashierName(String name) {
  final trimmed = name.trim();
  return trimmed.isNotEmpty && trimmed.length <= 50;
}

/// Body dasar panggilan Edge Function kasir yang butuh bukti Owner
/// (list/register/set-pin/set-active).
///
/// PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026, Batch C10.1): SATU
/// PIN untuk semua gerai — hash-nya hanya ada di baris outlet global
/// (...0001). Jadi [outlet_id] yang dikirim SELALU baris global,
/// BUKAN gerai yang sedang dipilih (gerai lain akan dijawab EF
/// `not_set` bila mengirim outlet_id-nya sendiri). Fungsi ini sengaja
/// TIDAK menerima outlet_id — tidak ada jalan untuk mengirim yang
/// salah. Dipakai keempat metode Owner di [CashierService]; tes
/// menegaskan body-nya selalu global (test/cashier_service_test.dart).
Map<String, dynamic> cashierOwnerBody({
  required String ownerPin,
  Map<String, dynamic> extra = const {},
}) {
  return {
    'outlet_id': PinService.defaultOutletId,
    'owner_pin': ownerPin,
    ...extra,
  };
}

/// Registri kasir (Batch C8.2): Owner mendaftarkan kasir (nama + PIN
/// 6 digit, berlaku di semua gerai); kasir login HANYA dengan PIN —
/// identitas (id + nama) datang dari server, bukan ketikan kasir.
/// Semua operasi lewat Edge Function (service_role); PIN tidak pernah
/// disimpan lokal — bahkan hash-nya tidak di-cache.
///
/// PIN Owner diverifikasi server di tiap panggilan (bukti Owner);
/// PIN Owner itu sendiri tidak disimpan di sini — pemanggil
/// meneruskannya sekali dari PinEntryDialog.onPinVerified.
class CashierService {
  CashierService._();

  static final CashierService instance = CashierService._();

  /// Batas percobaan di sisi app (server punya batas sendiri di
  /// pin_attempts, sama seperti PIN Owner).
  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(minutes: 5);

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  bool get isLocked =>
      _lockedUntil != null && DateTime.now().isBefore(_lockedUntil!);

  int get remainingAttempts => maxAttempts - _failedAttempts;

  String get _outletId => OutletService.instance.currentOutletId;

  /// Verifikasi PIN akses kasir (login + layar kunci). Fail closed:
  /// salah / terkunci / belum ada kasir / offline = tidak masuk.
  Future<({
    CashierVerifyResult result,
    String? cashierId,
    String? name,
  })> verifyPin(String pin, {String? outletId}) async {
    if (isLocked) {
      return (
        result: CashierVerifyResult.locked,
        cashierId: null,
        name: null,
      );
    }
    if (!PinService.isValidPin(pin)) {
      return (
        result: CashierVerifyResult.wrong,
        cashierId: null,
        name: null,
      );
    }
    if (!SupabaseService.instance.isConfigured) {
      return (
        result: CashierVerifyResult.unavailable,
        cashierId: null,
        name: null,
      );
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'verify-cashier-pin',
        body: {'pin': pin, 'outlet_id': outletId ?? _outletId},
      );
      final parsed = parseVerifyCashierResponse(res.data);
      if (parsed.result == CashierVerifyResult.ok) {
        _failedAttempts = 0;
        _lockedUntil = null;
      } else if (parsed.result == CashierVerifyResult.wrong) {
        _failedAttempts++;
        if (_failedAttempts >= maxAttempts) {
          _lockedUntil = DateTime.now().add(lockoutDuration);
        }
      }
      return parsed;
    } catch (e) {
      debugPrint('Verifikasi PIN kasir gagal: $e');
      return (
        result: CashierVerifyResult.unavailable,
        cashierId: null,
        name: null,
      );
    }
  }

  /// Daftarkan kasir baru (Owner). [error] = kode server
  /// ('pin_taken' / 'name_taken' / pesan lain) bila gagal.
  Future<({bool ok, String? cashierId, String? error})> registerCashier({
    required String ownerPin,
    required String name,
    required String pin,
  }) async {
    if (!isValidCashierName(name)) {
      return (ok: false, cashierId: null, error: 'name_invalid');
    }
    if (!PinService.isValidPin(pin)) {
      return (ok: false, cashierId: null, error: 'pin_invalid');
    }
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, cashierId: null, error: 'offline');
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'register-cashier',
        body: cashierOwnerBody(
          ownerPin: ownerPin,
          extra: {'name': name.trim(), 'pin': pin},
        ),
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        final id = data['cashier_id'];
        return (
          ok: true,
          cashierId: id is String ? id : null,
          error: null,
        );
      }
      return (
        ok: false,
        cashierId: null,
        error: parseCashierError(data) ?? 'unknown',
      );
    } catch (e) {
      debugPrint('Daftar kasir gagal: $e');
      return (ok: false, cashierId: null, error: 'offline');
    }
  }

  /// Daftar semua kasir terdaftar (Owner). [ok] = false bila gagal
  /// dimuat (offline / PIN ditolak / EF belum di-deploy).
  Future<({bool ok, List<Cashier> cashiers})> listCashiers({
    required String ownerPin,
  }) async {
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, cashiers: const <Cashier>[]);
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'list-cashiers',
        body: cashierOwnerBody(ownerPin: ownerPin),
      );
      return parseCashierListResponse(res.data);
    } catch (e) {
      debugPrint('Muat daftar kasir gagal: $e');
      return (ok: false, cashiers: const <Cashier>[]);
    }
  }

  /// Ubah PIN akses satu kasir (Owner). [error] = kode server
  /// ('pin_taken' / 'cashier_not_found' / pesan lain) bila gagal.
  Future<({bool ok, String? error})> setCashierPin({
    required String ownerPin,
    required String cashierId,
    required String pin,
  }) async {
    if (!PinService.isValidPin(pin)) {
      return (ok: false, error: 'pin_invalid');
    }
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, error: 'offline');
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-cashier-pin',
        body: cashierOwnerBody(
          ownerPin: ownerPin,
          extra: {'cashier_id': cashierId, 'pin': pin},
        ),
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        return (ok: true, error: null);
      }
      return (ok: false, error: parseCashierError(data) ?? 'unknown');
    } catch (e) {
      debugPrint('Ubah PIN kasir gagal: $e');
      return (ok: false, error: 'offline');
    }
  }

  /// Nonaktifkan / aktifkan lagi satu kasir (Owner).
  Future<bool> setCashierActive({
    required String ownerPin,
    required String cashierId,
    required bool active,
  }) async {
    if (!SupabaseService.instance.isConfigured) return false;
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-cashier-active',
        body: cashierOwnerBody(
          ownerPin: ownerPin,
          extra: {'cashier_id': cashierId, 'active': active},
        ),
      );
      final data = res.data;
      return data is Map && data['ok'] == true;
    } catch (e) {
      debugPrint('Ubah status kasir gagal: $e');
      return false;
    }
  }
}
