import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/supabase_client.dart';
import 'qris_crypto.dart';
import 'qris_service.dart';

/// Penyimpanan kode QRIS statis merchant (Owner saja).
///
/// Nilai asli TIDAK PERNAH di-hardcode di repo: Owner menempelkannya di
/// layar Pengaturan QRIS, lalu disimpan ke Supabase (`app_settings`,
/// key `qris_static_payload`, RLS Owner-only) bila outlet + Supabase
/// sudah dikonfigurasi. Sebelum itu, nilai hanya hidup di memori aplikasi.
///
/// Batch C2 (RedMuse F2): nilai yang disimpan di Supabase TERENKRIPSI
/// (AES-256-GCM, format `enc:v1:` + base64 nonce+ciphertext+tag).
/// Kunci 32 byte dibuat sekali dan disimpan di perangkat (Android
/// Keystore via flutter_secure_storage) — TIDAK PERNAH ikut ke
/// Supabase, Drift, atau kode. Plaintext hanya hidup di memori saat
/// generate QR (tidak terhindarkan — QR dinamis dibuat dari payload
/// asli). Nilai plaintext LAMA (sebelum C2) tetap bisa dibaca dan
/// dimigrasikan ke terenkripsi saat pertama dibaca (migration-on-read).
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
      final row = await SupabaseService.instance.client
          .from('app_settings')
          .select('value')
          .eq('outlet_id', currentOutletId!)
          .eq('key', 'qris_static_payload')
          .maybeSingle();
      final value = (row as Map?)?['value'] as String?;
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
      // Nilai lama (plaintext, sebelum C2) — tetap bisa dipakai, lalu
      // dimigrasikan ke terenkripsi supaya tidak lagi tersimpan polos.
      if (QrisService.isValidStaticPayload(value)) {
        _staticPayload = value;
        final encrypted = await _encryptPayload(value);
        if (encrypted != null) {
          try {
            await SupabaseService.instance.client
                .from('app_settings')
                .upsert({
              'outlet_id': currentOutletId,
              'key': 'qris_static_payload',
              'value': encrypted,
            });
          } catch (e) {
            debugPrint('Migrasi payload QRIS ke terenkripsi gagal: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Muat pengaturan QRIS gagal (pakai memori): $e');
    }
  }

  /// Simpan payload statis (sudah divalidasi pemanggil).
  /// [ok] = false bila payload tidak valid ATAU enkripsi tidak
  /// tersedia di perangkat ini (fail closed — jangan simpan plaintext
  /// baru). [synced] = true bila nilai sudah sampai ke Supabase;
  /// false = nilai hanya di memori sesi ini (Supabase belum aktif
  /// atau upsert gagal) — hilang saat restart, jadi halaman wajib
  /// membedakan pesannya, jangan bilang "tersimpan" tanpa syarat.
  Future<({bool ok, bool synced})> save(String payload) async {
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
      await SupabaseService.instance.client.from('app_settings').upsert({
        'outlet_id': currentOutletId,
        'key': 'qris_static_payload',
        'value': encrypted,
      });
      return (ok: true, synced: true);
    } catch (e) {
      debugPrint('Simpan pengaturan QRIS ke Supabase gagal: $e');
      return (ok: true, synced: false);
    }
  }

  Future<void> clear() async {
    _staticPayload = null;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return;
    }
    try {
      await SupabaseService.instance.client
          .from('app_settings')
          .delete()
          .eq('outlet_id', currentOutletId!)
          .eq('key', 'qris_static_payload');
    } catch (e) {
      debugPrint('Hapus pengaturan QRIS gagal: $e');
    }
  }
}
