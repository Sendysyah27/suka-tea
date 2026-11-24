import 'package:flutter/foundation.dart';

import '../../data/supabase_client.dart';
import 'pin_service.dart';

/// PIN Kasir per gerai (Batch C4 multi-gerai) — pola yang sama dengan
/// PIN Owner: hash bcrypt HANYA di Supabase (app_settings, key
/// `kasir_pin_hash`, per outlet_id), verifikasi + atur lewat Edge
/// Function BARU (verify-kasir-pin / set-kasir-pin / kasir-pin-status).
/// PIN kasir TIDAK PERNAH disimpan lokal — bahkan hash-nya tidak
/// di-cache.
///
/// DEPRECATED — Batch C8.2 (24 Nov 2026): PIN kasir per-gerai TIDAK
/// LAGI dipakai. Kasir kini didaftarkan Owner di "Kelola Kasir"
/// (lib/features/kasir/cashier_service.dart) — satu PIN berlaku di
/// semua gerai, identitas dari server. File ini + dialog-nya +
/// ketiga Edge Function-nya SENGAJA DIBIARKAN (bukan dihapus) supaya
/// rollback / audit tetap bisa — tapi tidak ada pemakai lagi di app.
///
/// STATUS DEPLOY (jujur): ketiga Edge Function itu SUDAH ada sebagai
/// file di repo (supabase/functions/verify-kasir-pin/ dst) tapi BELUM
/// di-deploy ke dashboard Supabase — Jhon yang deploy. Selama
/// fungsinya belum ada, [verify]/[isPinSet] mengembalikan
/// `unavailable`/null, dan halaman Login memperlakukan itu sebagai
/// "PIN kasir belum diatur" (kasir masuk langsung, seperti perilaku
/// app sebelum C4) — supaya kasir tetap bisa jualan offline.
/// PIN Owner TIDAK ikut pola ini (fail closed — lihat pin_service).
class KasirPinService {
  KasirPinService._();

  static final KasirPinService instance = KasirPinService._();

  /// Batas percobaan di sisi app (server punya batas sendiri di
  /// pin_attempts, sama seperti PIN Owner).
  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(minutes: 5);

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  bool get isLocked =>
      _lockedUntil != null && DateTime.now().isBefore(_lockedUntil!);

  int get remainingAttempts => maxAttempts - _failedAttempts;

  /// Verifikasi PIN Kasir satu gerai. [outletId] wajib (per gerai).
  Future<PinVerifyResult> verify(String outletId, String pin) async {
    if (isLocked) return PinVerifyResult.locked;
    if (!PinService.isValidPin(pin)) return PinVerifyResult.wrong;
    if (!SupabaseService.instance.isConfigured) {
      return PinVerifyResult.unavailable;
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'verify-kasir-pin',
        body: {'outlet_id': outletId, 'pin': pin},
      );
      final data = res.data;
      if (data is! Map) return PinVerifyResult.unavailable;
      if (data['ok'] == true) {
        _failedAttempts = 0;
        _lockedUntil = null;
        return PinVerifyResult.ok;
      }
      switch (data['reason']) {
        case 'not_set':
          return PinVerifyResult.notSet;
        case 'locked':
          return PinVerifyResult.locked;
        default:
          _failedAttempts++;
          if (_failedAttempts >= maxAttempts) {
            _lockedUntil = DateTime.now().add(lockoutDuration);
          }
          return PinVerifyResult.wrong;
      }
    } catch (e) {
      debugPrint('Verifikasi PIN Kasir gagal: $e');
      return PinVerifyResult.unavailable;
    }
  }

  /// Atur PIN Kasir pertama atau ubah PIN yang sudah ada.
  /// Salah satu dari dua bukti wajib ada:
  /// - [currentPin]: PIN Kasir lama (bila kasir sendiri yang ubah),
  /// - [ownerPin]: PIN Owner gerai itu (bila Owner yang ubah dari
  ///   Ubah Gerai — PIN Owner diverifikasi server di Edge Function,
  ///   TIDAK PERNAH disimpan).
  /// Bila PIN Kasir belum pernah diatur, tidak perlu bukti apa pun
  /// (setup pertama — tapi halaman Ubah Gerai tetap minta PIN Owner
  /// dulu di sisi app).
  Future<bool> setPin({
    required String outletId,
    String? currentPin,
    String? ownerPin,
    required String newPin,
  }) async {
    if (!PinService.isValidPin(newPin)) return false;
    if (!SupabaseService.instance.isConfigured) return false;
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-kasir-pin',
        body: {
          'outlet_id': outletId,
          if (currentPin != null) 'current_pin': currentPin,
          if (ownerPin != null) 'owner_pin': ownerPin,
          'new_pin': newPin,
        },
      );
      final data = res.data;
      return data is Map && data['ok'] == true;
    } catch (e) {
      debugPrint('Atur PIN Kasir gagal: $e');
      return false;
    }
  }

  /// Apakah PIN Kasir sudah diatur untuk satu gerai.
  /// null = tidak bisa dicek (offline / fungsi belum di-deploy).
  Future<bool?> isPinSet(String outletId) async {
    if (!SupabaseService.instance.isConfigured) return null;
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'kasir-pin-status',
        body: {'outlet_id': outletId},
      );
      final data = res.data;
      if (data is! Map || data['ok'] != true) return null;
      return data['set'] == true;
    } catch (e) {
      debugPrint('Cek status PIN Kasir gagal: $e');
      return null;
    }
  }
}
