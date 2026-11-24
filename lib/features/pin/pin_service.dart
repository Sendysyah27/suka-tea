import 'package:flutter/foundation.dart';

import '../../data/supabase_client.dart';
import '../login/cashier_session.dart';

/// PIN Owner — gerbang mode Owner. Aturan keras (perintah Sendy 22 Nov 2026):
/// PIN hanya tersimpan di Supabase sebagai hash bcrypt (app_settings, key
/// `owner_pin_hash`) — TIDAK PERNAH tersimpan di HP, repo, atau chat.
/// Verifikasi + atur PIN lewat Edge Function (service_role); hash tidak
/// pernah keluar dari server. Gagal verifikasi = tetap Kasir (fail closed).
/// PIN TIDAK PERNAH disimpan lokal — bahkan hash-nya tidak di-cache.
///
/// PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026): SATU PIN untuk semua gerai.
/// Semua operasi di bawah ini selalu memakai outlet global (...0001);
/// parameter [outletId] di tiap method DIABAIKAN (diterima hanya supaya
/// pemanggil lama — dialog PIN, Pengaturan, login — tidak berubah).
/// Server (Edge Function) juga menormalisasi ke baris global, jadi app
/// versi lama ikut jadi global begitu EF baru di-deploy.
enum PinVerifyResult { ok, wrong, locked, notSet, unavailable }

class PinService {
  PinService._();

  static final PinService instance = PinService._();

  /// Outlet default (migrasi 003) — dipakai sampai pemilihan outlet (M0) ada.
  static const String defaultOutletId =
      '00000000-0000-0000-0000-000000000001';

  static const int pinLength = 6;

  /// Batas percobaan di sisi app (server punya batas sendiri di pin_attempts).
  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(minutes: 5);

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  bool get isLocked =>
      _lockedUntil != null && DateTime.now().isBefore(_lockedUntil!);

  int get remainingAttempts => maxAttempts - _failedAttempts;

  static bool isValidPin(String pin) => RegExp(r'^\d{6}$').hasMatch(pin);

  /// Verifikasi PIN Owner GLOBAL — satu PIN untuk semua gerai.
  /// [outletId] diabaikan (lihat doc class) — selalu outlet global.
  Future<PinVerifyResult> verify(String pin, {String? outletId}) async {
    if (isLocked) return PinVerifyResult.locked;
    if (!isValidPin(pin)) return PinVerifyResult.wrong;
    if (!SupabaseService.instance.isConfigured) {
      return PinVerifyResult.unavailable;
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'verify-owner-pin',
        body: {'outlet_id': defaultOutletId, 'pin': pin},
      );
      final data = res.data;
      if (data is! Map) return PinVerifyResult.unavailable;
      if (data['ok'] == true) {
        _failedAttempts = 0;
        _lockedUntil = null;
        // SEC-1 R-02: simpan PIN Owner sesi di MEMORI (bukan storage)
        // supaya sync-sales/export-sheets bisa membawa bukti.
        CashierSessionService.instance.rememberOwnerPin(pin);
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
      debugPrint('Verifikasi PIN gagal: $e');
      return PinVerifyResult.unavailable;
    }
  }

  /// Atur PIN pertama (currentPin null) atau ubah PIN (currentPin wajib).
  /// GLOBAL — PIN baru berlaku di semua gerai. [outletId] diabaikan.
  Future<bool> setPin({
    String? currentPin,
    required String newPin,
    String? outletId,
  }) async {
    if (!isValidPin(newPin)) return false;
    if (!SupabaseService.instance.isConfigured) return false;
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-owner-pin',
        body: {
          'outlet_id': defaultOutletId,
          if (currentPin != null) 'current_pin': currentPin,
          'new_pin': newPin,
        },
      );
      final data = res.data;
      return data is Map && data['ok'] == true;
    } catch (e) {
      debugPrint('Atur PIN gagal: $e');
      return false;
    }
  }

  /// Apakah PIN sudah diatur (untuk label status di Pengaturan).
  /// null = tidak bisa dicek (offline / fungsi belum di-deploy).
  /// GLOBAL — cek baris global. [outletId] diabaikan.
  Future<bool?> isPinSet({String? outletId}) async {
    if (!SupabaseService.instance.isConfigured) return null;
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'pin-status',
        body: {'outlet_id': defaultOutletId},
      );
      final data = res.data;
      if (data is! Map || data['ok'] != true) return null;
      return data['set'] == true;
    } catch (e) {
      debugPrint('Cek status PIN gagal: $e');
      return null;
    }
  }
}
