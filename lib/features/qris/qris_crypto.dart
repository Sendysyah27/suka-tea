import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

/// Enkripsi payload QRIS statis merchant (AES-256-GCM) — Batch C2
/// (RedMuse F2: payload selama ini plaintext di Supabase `app_settings`).
///
/// Wire format: `enc:v1:` + base64(nonce 12 byte + ciphertext + tag 16
/// byte). Nonce acak tiap enkripsi — dua enkripsi nilai yang sama
/// menghasilkan string berbeda. Prefix membedakan nilai terenkripsi
/// dari nilai plaintext lama (sebelum C2).
///
/// Kunci 32 byte disimpan di perangkat (Android Keystore via
/// flutter_secure_storage) dan TIDAK PERNAH ikut ke Supabase/repo.
/// Plaintext hanya hidup di memori aplikasi saat generate QR —
/// itu tidak terhindarkan (QR dinamis harus dibuat dari payload asli).
/// Yang dilindungi di sini adalah nilai DIAM di Supabase.
///
/// Fungsi di sini murni (tanpa Flutter/platform channel) supaya bisa
/// di-unit-test tanpa perangkat. Gagal dekripsi (kunci salah, data
/// rusak, tag GCM tidak cocok) mengembalikan null — jangan pernah
/// throw ke pemanggil; payload yang gagal dibuka dianggap belum diatur.
class QrisCrypto {
  QrisCrypto._();

  /// Prefix nilai terenkripsi di `app_settings`.
  static const String prefix = 'enc:v1:';

  /// Panjang nonce GCM (standar 12 byte) + kunci AES-256 (32 byte).
  static const int nonceLength = 12;
  static const int keyLength = 32;

  /// true bila [value] berformat terenkripsi (bukan plaintext lama).
  static bool isEncrypted(String value) => value.startsWith(prefix);

  /// Kunci AES-256 baru (32 byte acak aman).
  static Uint8List generateKey() => Key.fromSecureRandom(keyLength).bytes;

  /// Enkripsi [plaintext] dengan [key] (32 byte). Throws
  /// [ArgumentError] bila panjang kunci salah.
  static String encrypt(String plaintext, Uint8List key) {
    if (key.length != keyLength) {
      throw ArgumentError('Kunci enkripsi harus $keyLength byte.');
    }
    final encrypter = Encrypter(AES(Key(key), mode: AESMode.gcm));
    final iv = IV.fromSecureRandom(nonceLength);
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final combined = Uint8List(nonceLength + encrypted.bytes.length)
      ..setAll(0, iv.bytes)
      ..setAll(nonceLength, encrypted.bytes);
    return '$prefix${base64Encode(combined)}';
  }

  /// Dekripsi nilai berformat [prefix]. Null bila bukan format
  /// terenkripsi, kunci salah/panjang salah, atau data rusak.
  static String? decrypt(String value, Uint8List key) {
    if (!isEncrypted(value) || key.length != keyLength) return null;
    try {
      final combined = base64Decode(value.substring(prefix.length));
      if (combined.length <= nonceLength) return null;
      final iv = IV(combined.sublist(0, nonceLength));
      final cipherBytes = combined.sublist(nonceLength);
      final encrypter = Encrypter(AES(Key(key), mode: AESMode.gcm));
      return encrypter.decrypt(Encrypted(cipherBytes), iv: iv);
    } catch (_) {
      return null;
    }
  }
}
