import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/supabase_client.dart';
import 'qris_crypto.dart';
import 'qris_service.dart';

/// Hasil mentah Edge Function `get-qris-payload` -> (ok, value).
/// [ok] = false bila bukan peta / ok != true / value bukan null atau
/// ciphertext `enc:v1:` — fail closed: plaintext dari server TIDAK
/// PERNAH diterima (EF menolak plaintext; RLS memblokir tulis langsung
/// sejak migrasi 002, jadi baris plaintext seharusnya tidak ada).
/// [value] = null bila belum diatur (`set:false`).
({bool ok, String? value}) parseGetQrisResponse(dynamic data) {
  if (data is! Map) return (ok: false, value: null);
  if (data['ok'] != true) return (ok: false, value: null);
  final value = data['value'];
  if (value == null) return (ok: true, value: null);
  if (value is! String || !QrisCrypto.isEncrypted(value)) {
    return (ok: false, value: null);
  }
  return (ok: true, value: value);
}

/// Hasil mentah Edge Function `set-qris-payload` -> true bila ok.
/// Dipakai save() + clear(): 2xx dengan {ok:true} = berhasil.
bool parseSetQrisResponse(dynamic data) {
  if (data is! Map) return false;
  return data['ok'] == true;
}

/// Penyimpanan kode QRIS statis merchant (Owner saja).
///
/// Nilai asli TIDAK PERNAH di-hardcode di repo: Owner menempelkannya di
/// layar Pengaturan QRIS, lalu disimpan ke Supabase (`app_settings`,
/// key `qris_static_payload`) bila outlet + Supabase sudah
/// dikonfigurasi. Sebelum itu, nilai hanya hidup di memori aplikasi.
///
/// Batch C2 (RedMuse F2): nilai yang disimpan di Supabase TERENKRIPSI
/// (AES-256-GCM, format `enc:v1:` + base64 nonce+ciphertext+tag).
/// Kunci 32 byte dibuat sekali dan disimpan di perangkat (Android
/// Keystore via flutter_secure_storage) — TIDAK PERNAH ikut ke
/// Supabase, Drift, atau kode. Plaintext hanya hidup di memori saat
/// generate QR (tidak terhindarkan — QR dinamis dibuat dari payload
/// asli).
///
/// Batch C8: simpan/baca LEWAT Edge Function (`set-qris-payload` /
/// `get-qris-payload`), BUKAN upsert/select langsung dari app.
/// `app_settings` (migrasi 002) RLS-nya nyala dengan SATU policy
/// "owner kelola pengaturan" (is_outlet_owner via auth.uid()) —
/// sedangkan app TIDAK PERNAH login Supabase Auth, jadi baca/tulis
/// langsung pakai anon key SELALU ditolak server. Terbukti 24 Nov 2026:
/// app_settings cuma berisi owner_pin_hash + kasir_pin_hash, TIDAK ADA
/// baris qris_static_payload — payload cuma hidup di memori + hilang
/// tiap restart. EF memakai service_role (melewati RLS); bukti Owner
/// adalah PIN Owner yang diverifikasi server-side di `set-qris-payload`
/// (pola upload-product-photo). `get-qris-payload` tanpa cek PIN —
/// kasir butuh ciphertext ini tiap generate QR, dan ciphertext tidak
/// berguna tanpa kunci enkripsi perangkat.
class QrisSettingsService {
  QrisSettingsService._();

  static final QrisSettingsService instance = QrisSettingsService._();

  /// Kunci kunci-enkripsi di secure storage perangkat.
  static const _keyStorageKey = 'qris_payload_key';

  final _secureStorage = const FlutterSecureStorage();

  /// Diisi app saat outlet aktif dipilih (sesudah login — gerai aktif
  /// baru diketahui di halaman Login, bukan di main()). Null = belum
  /// ada outlet. Mengganti outlet me-reset status load supaya payload
  /// gerai baru dibaca (bukan payload gerai lama yang tertinggal).
  String? _currentOutletId;
  String? get currentOutletId => _currentOutletId;
  set currentOutletId(String? value) {
    if (value != _currentOutletId) {
      _currentOutletId = value;
      _loaded = false;
    }
  }

  String? _staticPayload;
  bool _loaded = false;

  String? get staticPayload => _staticPayload;

  bool get isConfigured =>
      _staticPayload != null && _staticPayload!.isNotEmpty;

  String? get merchantName =>
      _staticPayload == null ? null : QrisService.merchantName(_staticPayload!);

  /// Baca kunci dari secure storage (null bila belum ada / rusak).
  /// TIDAK membuat kunci baru — dipakai saat memuat (load tidak boleh
  /// membuat kunci hanya karena membaca).
  Future<Uint8List?> _readKey() async {
    try {
      final stored = await _secureStorage.read(key: _keyStorageKey);
      if (stored == null) return null;
      final bytes = base64Decode(stored);
      return bytes.length == QrisCrypto.keyLength ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  /// Baca kunci, atau buat + simpan bila belum ada. Null bila secure
  /// storage tidak bisa dipakai di perangkat ini.
  Future<Uint8List?> _getOrCreateKey() async {
    final existing = await _readKey();
    if (existing != null) return existing;
    try {
      final key = QrisCrypto.generateKey();
      await _secureStorage.write(
        key: _keyStorageKey,
        value: base64Encode(key),
      );
      return key;
    } catch (e) {
      debugPrint('Kunci QRIS tidak bisa dibuat/disimpan: $e');
      return null;
    }
  }

  /// Enkripsi payload untuk disimpan. Null bila kunci tidak tersedia.
  Future<String?> _encryptPayload(String plaintext) async {
    final key = await _getOrCreateKey();
    if (key == null) return null;
    try {
      return QrisCrypto.encrypt(plaintext, key);
    } catch (e) {
      debugPrint('Enkripsi payload QRIS gagal: $e');
      return null;
    }
  }

  /// Muat payload dari Supabase lewat Edge Function `get-qris-payload`
  /// (service_role). Nilai terenkripsi dibuka dengan kunci perangkat;
  /// bila kunci hilang/rusak, payload dianggap belum diatur.
  /// Plaintext dari server DITOLAK (fail closed) — EF tidak pernah
  /// menulis plaintext, dan tulis langsung sudah diblokir RLS sejak
  /// migrasi 002, jadi baris plaintext seharusnya tidak ada.
  /// Migration-on-read DIHAPUS (Batch C8): load() tidak punya PIN
  /// Owner, jadi tidak bisa lagi menulis balik ke Supabase.
  Future<void> load() async {
    if (_loaded) return;
    // _loaded HANYA diset sesudah percobaan baca yang sesungguhnya —
    // kalau outlet/Supabase belum siap, load() berikutnya harus
    // mencoba lagi (bukan mengira sudah dimuat).
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return;
    }
    _loaded = true;
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'get-qris-payload',
        body: {'outlet_id': currentOutletId},
      );
      final parsed = parseGetQrisResponse(res.data);
      if (!parsed.ok) {
        debugPrint(
          'Muat pengaturan QRIS gagal: jawaban get-qris-payload tidak dikenal.',
        );
        return;
      }
      final value = parsed.value;
      if (value == null) return;
      if (QrisCrypto.isEncrypted(value)) {
        final key = await _readKey();
        final plain = key == null ? null : QrisCrypto.decrypt(value, key);
        if (plain != null && QrisService.isValidStaticPayload(plain)) {
          _staticPayload = plain;
        } else {
          debugPrint(
            'Payload QRIS terenkripsi tidak bisa dibuka — kunci hilang '
            'atau data rusak. Minta Owner simpan ulang QRIS merchant.',
          );
        }
        return;
      }
      // Bukan `enc:v1:` — parseGetQrisResponse sudah menolaknya, jadi
      // jalur ini tidak terjangkau; dipertahankan sebagai jaring
      // pengaman bila parse berubah di masa depan.
      debugPrint(
        'Payload QRIS dari server bukan format enc:v1: — diabaikan.',
      );
    } on FunctionException catch (e) {
      // Edge Function mengembalikan 4xx/5xx dengan body JSON {ok, error}:
      // details membawa body itu. NAMA KELAS: `FunctionException`
      // (tunggal) — supabase_flutter 2.x. JANGAN "diperbaiki" ke
      // `FunctionsException` (itu 3.x — ketangkep CI v28).
      debugPrint(
        'Muat pengaturan QRIS gagal (${e.status}): ${e.details} (pakai memori).',
      );
    } catch (e) {
      debugPrint('Muat pengaturan QRIS gagal (pakai memori): $e');
    }
  }

  /// Simpan payload statis (sudah divalidasi pemanggil) lewat Edge
  /// Function `set-qris-payload`. [ownerPin] = PIN Owner yang sudah
  /// diverifikasi halaman lewat PinEntryDialog — diteruskan sekali ke
  /// server, TIDAK PERNAH disimpan di sini.
  /// [ok] = false bila payload tidak valid ATAU enkripsi tidak
  /// tersedia di perangkat ini (fail closed — jangan simpan plaintext
  /// baru). [synced] = true bila nilai sudah sampai ke Supabase;
  /// false = nilai hanya di memori sesi ini (Supabase belum aktif,
  /// PIN ditolak server, atau EF belum di-deploy) — hilang saat
  /// restart, jadi halaman wajib membedakan pesannya, jangan bilang
  /// "tersimpan" tanpa syarat.
  Future<({bool ok, bool synced})> save(
    String payload, {
    required String ownerPin,
  }) async {
    if (!QrisService.isValidStaticPayload(payload)) {
      return (ok: false, synced: false);
    }
    final encrypted = await _encryptPayload(payload);
    if (encrypted == null) return (ok: false, synced: false);
    _staticPayload = payload;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return (ok: true, synced: false);
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-qris-payload',
        body: {
          'outlet_id': currentOutletId,
          'pin': ownerPin,
          'value': encrypted,
        },
      );
      final synced = parseSetQrisResponse(res.data);
      if (!synced) {
        debugPrint(
          'Simpan pengaturan QRIS ditolak server: ${res.data}.',
        );
      }
      return (ok: true, synced: synced);
    } on FunctionException catch (e) {
      // NAMA KELAS: `FunctionException` (tunggal) — supabase_flutter
      // 2.x. JANGAN "diperbaiki" ke `FunctionsException` (itu 3.x —
      // ketangkep CI v28).
      debugPrint(
        'Simpan pengaturan QRIS ke Supabase gagal (${e.status}): ${e.details}.',
      );
      return (ok: true, synced: false);
    } catch (e) {
      debugPrint('Simpan pengaturan QRIS ke Supabase gagal: $e');
      return (ok: true, synced: false);
    }
  }

  /// Hapus payload QRIS: memori dibersihkan dulu, lalu baris di
  /// Supabase dihapus lewat Edge Function `set-qris-payload`
  /// (delete:true) dengan bukti PIN Owner. Mengembalikan true bila
  /// baris server terhapus; false bila server tidak bisa dihubungi /
  /// PIN ditolak / Supabase belum dikonfigurasi — baris server (bila
  /// ada) akan dimuat lagi saat load() berikutnya.
  Future<bool> clear({required String ownerPin}) async {
    _staticPayload = null;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return false;
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-qris-payload',
        body: {
          'outlet_id': currentOutletId,
          'pin': ownerPin,
          'delete': true,
        },
      );
      return parseSetQrisResponse(res.data);
    } on FunctionException catch (e) {
      // NAMA KELAS: `FunctionException` (tunggal) — supabase_flutter
      // 2.x. JANGAN "diperbaiki" ke `FunctionsException` (itu 3.x —
      // ketangkep CI v28).
      debugPrint(
        'Hapus pengaturan QRIS di Supabase gagal (${e.status}): ${e.details}.',
      );
      return false;
    } catch (e) {
      debugPrint('Hapus pengaturan QRIS di Supabase gagal: $e');
      return false;
    }
  }
}
